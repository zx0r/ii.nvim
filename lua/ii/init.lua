-- ii.nvim: bounded asynchronous IXPC client for Neovim (0.12+)
-- Protocol: IXPC v1 DecorateBuffer (0x0008): format + unsaved bytes -> graphics + ANSI.
-- One request per window. Source data stays owned by Neovim.

local M = {}
local transparent = "NONE"
local is_mac = vim.fn.has("mac") == 1
local cached_cell_w, cached_cell_h = is_mac and 18 or 9, is_mac and 36 or 18
local frames = {}
local saved = {}
local deadlines = {}
local errors = {}
local options = { executable = "ii", timeout_ms = 5000 }
local buffer_enabled = {}
local generations = {}
local next_generation = 0
local requests = {}
local timers = {}
local suspended_highlights = {}
local yank_preview = {}
local placeholder = "\244\142\187\174"
local max_payload = 64 * 1024 * 1024

-- Little-endian packing helpers (LuaJIT / Lua 5.1 compatible, zero external dependencies)
local function pack_u16_le(val)
  local v = math.floor(val) % 65536
  return string.char(v % 256, math.floor(v / 256))
end

local function pack_u32_le(val)
  local v = math.floor(val) % 4294967296
  local b1 = v % 256
  v = math.floor(v / 256)
  local b2 = v % 256
  v = math.floor(v / 256)
  local b3 = v % 256
  local b4 = math.floor(v / 256)
  return string.char(b1, b2, b3, b4)
end

-- Little-endian unpacking helpers
local function unpack_u16_le(str, offset)
  local b1, b2 = string.byte(str, offset, offset + 1)
  return b1 + b2 * 256
end

local function unpack_u32_le(str, offset)
  local b1, b2, b3, b4 = string.byte(str, offset, offset + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Resolve IXPC v1 socket path (main loop safe)
local function get_socket_path()
  if vim.g.ii_socket_path and #vim.g.ii_socket_path > 0 then
    return vim.g.ii_socket_path
  end
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and #xdg > 0 and vim.uv.fs_stat(xdg) then
    return xdg .. "/ii/ii.sock"
  end
  local uid = vim.uv.getuid and vim.uv.getuid() or 1000
  return string.format("/tmp/ii-%d/ii.sock", uid)
end

-- Terminal cell size probe with tmux split protection
local function update_cell_metrics()
  if vim.env.TMUX then
    cached_cell_w, cached_cell_h = is_mac and 18 or 9, is_mac and 36 or 18
    return
  end

  local ffi = require("ffi")
  pcall(ffi.cdef, [[
    typedef struct { unsigned short row, col, xpixel, ypixel; } winsize;
    int ioctl(int, int, ...);
  ]])
  local TIOCGWINSZ = (is_mac or vim.fn.has("bsd") == 1) and 0x40087468 or 0x5413
  local sz = ffi.new("winsize")
  if ffi.C.ioctl(1, TIOCGWINSZ, sz) == 0 and sz.col > 0 and sz.row > 0 and sz.xpixel > 0 and sz.ypixel > 0 then
    cached_cell_w = math.max(4, math.floor(sz.xpixel / sz.col))
    cached_cell_h = math.max(8, math.floor(sz.ypixel / sz.row))
  else
    cached_cell_w, cached_cell_h = is_mac and 18 or 9, is_mac and 36 or 18
  end
end

update_cell_metrics()
vim.api.nvim_create_autocmd("VimResized", { callback = update_cell_metrics })

-- Connect to daemon with transparent autospawn on failure
local function connect_daemon(sock_path, cb, active, retries)
  if not active() then return end
  retries = retries or 0
  local pipe = vim.uv.new_pipe(false)

  pipe:connect(sock_path, function(err)
    if not active() then pipe:close(); return end
    if not err then
      cb(nil, pipe)
      return
    end

    pipe:close()
    if (err:match("ENOENT") or err:match("ECONNREFUSED")) and retries < 5 then
      if retries == 0 then vim.schedule(function()
        if not active() then return end
        local ok, spawn_err = pcall(vim.system, { options.executable, "--daemon", "--socket", sock_path }, { detach = true }, function(_) end)
        if not ok then cb(tostring(spawn_err), nil) end
      end) end

      local timer = vim.uv.new_timer()
      timer:start(40 * (retries + 1), 0, function()
        timer:stop()
        timer:close()
        connect_daemon(sock_path, cb, active, retries + 1)
      end)
    else
      cb(err, nil)
    end
  end)
end

-- Parse ANSI once per completed frame; redraw/mouse motion never runs a parser or IPC.
local function virtual_lines(text, groups, win)
  local lines, chunks = {}, {}
  local attrs = {bg=transparent}; local group = "Normal"; local pos=1
  local function highlight()
    local key = (attrs.fg or "default") .. (attrs.bold and "b" or "") .. (attrs.italic and "i" or "") .. (attrs.strikethrough and "s" or "") .. (attrs.underline and "u" or "")
    if not groups[key] then
      groups.count=groups.count+1
      groups[key]="Ii_"..win.."_"..groups.count
      vim.api.nvim_set_hl(0,groups[key],attrs)
    end
    group=groups[key]
  end
  highlight()
  while pos<=#text do
    local at=text:find("\27[",pos,true)
    local nl=text:find("\n",pos,true)
    if nl and (not at or nl<at) then
      if nl>pos then chunks[#chunks+1]={text:sub(pos,nl-1),group} end
      lines[#lines+1]=chunks; chunks={};pos=nl+1
    elseif at then
      if at>pos then chunks[#chunks+1]={text:sub(pos,at-1),group} end
      local finish=text:find("m",at+2,true)
      if not finish then break end
      local params={};for n in text:sub(at+2,finish-1):gmatch("%d+") do params[#params+1]=tonumber(n) end
      local i=1
      while i<=#params do
        local n=params[i]
        if n==0 then attrs={bg=transparent} elseif n==1 then attrs.bold=true elseif n==3 then attrs.italic=true
        elseif n==4 then attrs.underline=true elseif n==9 then attrs.strikethrough=true
        elseif n==22 then attrs.bold=nil elseif n==23 then attrs.italic=nil
        elseif n==24 then attrs.underline=nil elseif n==29 then attrs.strikethrough=nil
        elseif n==39 then attrs.fg=nil
        elseif n==38 and params[i+1]==2 and params[i+4] then
          attrs.fg=string.format("#%02x%02x%02x",params[i+2],params[i+3],params[i+4]);i=i+4
        end
        i=i+1
      end
      highlight();pos=finish+1
    else chunks[#chunks+1]={text:sub(pos),group};pos=#text+1 end
  end
  if #chunks>0 then lines[#lines+1]=chunks end
  return lines
end

local view_options={conceallevel=2,concealcursor="nc",number=false,relativenumber=false,
  signcolumn="no",foldcolumn="0",statuscolumn="",winbar="",wrap=false,foldenable=false}
local function view_mode(win, rendered)
  if not vim.api.nvim_win_is_valid(win) then return end
  if rendered then
    if not saved[win] then
      -- A new split inherits its parent's rendered options. Keep the parent's
      -- source profile so Insert/Clear can restore the real editor settings.
      local inherited=true
      for name,value in pairs(view_options) do if vim.wo[win][name]~=value then inherited=false;break end end
      if inherited then
        for other,frame in pairs(frames) do
          if other~=win and frame.bufnr==vim.api.nvim_win_get_buf(win) and saved[other] then saved[win]=vim.deepcopy(saved[other]);break end
        end
      end
      if not saved[win] then
        saved[win]={}
        for name in pairs(view_options) do saved[win][name]=vim.wo[win][name] end
      end
    end
    for name,value in pairs(view_options) do if vim.wo[win][name]~=value then vim.wo[win][name]=value end end
  elseif saved[win] then
    for name,value in pairs(saved[win]) do if vim.wo[win][name]~=value then vim.wo[win][name]=value end end
  end
end

local function editing_source(mode)
  mode = (mode or vim.fn.mode()):sub(1, 1)
  return mode == "i" or mode == "R" or mode == "v" or mode == "V" or mode == "\22"
    or mode == "s" or mode == "S" or mode == "\19"
end

local function preview_visible(win, buf)
  return not editing_source() and not yank_preview[win] and vim.api.nvim_win_get_buf(win) == buf
end

local function sync_source_highlights(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then
    suspended_highlights[buf] = nil
    return
  end
  local active = vim.treesitter.highlighter.active[buf]
  if not editing_source() then
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    for win, frame in pairs(frames) do
      if frame.bufnr == buf and frame.tick == tick and frame.ns
          and vim.api.nvim_win_is_valid(win) and preview_visible(win, buf) then
        -- A Tree-sitter conceal_lines mark hides the rendered overlay and any
        -- virtual image rows anchored there. The preview supplies its own colors.
        if active then
          suspended_highlights[buf] = active.tree:lang()
          vim.treesitter.stop(buf)
        end
        return
      end
    end
  end
  local lang = suspended_highlights[buf]
  suspended_highlights[buf] = nil
  if lang and not active then vim.treesitter.start(buf, lang) end
end

local function discard(win)
  local frame = frames[win]
  if frame and frame.ns and vim.api.nvim_buf_is_valid(frame.bufnr) then
    vim.api.nvim_buf_clear_namespace(frame.bufnr, frame.ns, 0, -1)
  end
  frames[win] = nil
  yank_preview[win] = nil
  view_mode(win, false)
  saved[win] = nil
  if frame then sync_source_highlights(frame.bufnr) end
end

local function fail(win, bufnr, tick, message)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then return end
  if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then return end
  discard(win)
  errors[win] = { source = bufnr, message = message }
  vim.notify("ii: " .. message, vim.log.levels.WARN)
end

local function preview_anchors(block)
  local rows = {}
  local in_graphic = false
  local has_text = false
  for _, line in ipairs(block.lines) do
    local chunk = line[1]
    local graphic = #line == 1 and chunk[1]:sub(1, #placeholder) == placeholder
    local top = graphic and chunk[1]:sub(#placeholder + 1, #placeholder + 2) == "\204\133"
    local anchor = rows[#rows]
    if not anchor or (#rows < block.last - block.first and (not graphic or not in_graphic or top)) then
      rows[#rows + 1] = { text = line, below = {} }
    else
      anchor.below[#anchor.below + 1] = line
    end
    in_graphic = graphic
    has_text = has_text or not graphic
  end
  if #rows == 0 then rows[1] = { text = {}, below = {} } end
  return rows, #rows == 1 and in_graphic and not has_text
end

local function decorate(win)
  local frame=frames[win]
  if not frame or not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(frame.bufnr) then return end
  frame.ns=frame.ns or vim.api.nvim_create_namespace("ii_window_"..win)
  vim.api.nvim__ns_set(frame.ns,{wins={win}})
  vim.api.nvim_buf_clear_namespace(frame.bufnr,frame.ns,0,-1)
  local visible = preview_visible(win, frame.bufnr) and frame.tick == vim.api.nvim_buf_get_changedtick(frame.bufnr)
  view_mode(win, visible)
  sync_source_highlights(frame.bufnr)
  if not visible then return end
  for _, block in ipairs(frame.blocks) do
    local first = block.first
    if not block.anchors then block.anchors, block.standalone = preview_anchors(block) end
    local rows = block.anchors

    -- Anchor a standalone image at the end of its concealed source block.
    -- Continuation rows of embedded images also stay with their first row.
    if block.standalone and block.last - first > 1 then
      first = block.last - 1
      vim.api.nvim_buf_set_extmark(frame.bufnr, frame.ns, block.first, 0, {
        end_row = first - 1, end_col = 0, conceal_lines = "",
      })
    end
    local source = vim.api.nvim_buf_get_lines(frame.bufnr, first, first + #rows, false)
    for index, anchor in ipairs(rows) do
      local row = first + index - 1
      vim.api.nvim_buf_set_extmark(frame.bufnr, frame.ns, row, 0, {
        end_row = row, end_col = #(source[index] or ""), conceal = "", virt_text = anchor.text,
        virt_text_pos = "overlay", virt_lines = anchor.below, virt_lines_above = false,
      })
    end
    if block.last > first + #rows then
      vim.api.nvim_buf_set_extmark(frame.bufnr, frame.ns, first + #rows, 0, {
        end_row = block.last - 1, end_col = 0, conceal_lines = "",
      })
    end
  end
end

function M.render(bufnr, win, force)
  if vim.fn.mode():match("^[iR]") then return end
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return end
  bufnr = bufnr or vim.api.nvim_win_get_buf(win)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.api.nvim_win_get_buf(win) ~= bufnr or buffer_enabled[bufnr] == false then return end
  -- Rendered width excludes gutters. Apply window options only on commit.
  local cols = vim.api.nvim_win_get_width(win)
  local rows = math.max(1, vim.api.nvim_win_get_height(win))
  local background=vim.o.background
  local cell_w,cell_h=cached_cell_w,cached_cell_h
  local cached=frames[win]
  if not force and cached and cached.bufnr==bufnr and cached.tick==vim.api.nvim_buf_get_changedtick(bufnr)
    and cached.cols==cols and cached.rows==rows and cached.background==background
    and cached.cell_w==cell_w and cached.cell_h==cell_h then
    sync_source_highlights(bufnr)
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  next_generation = next_generation + 1
  local generation = next_generation
  generations[win] = generation
  if requests[win] and not requests[win]:is_closing() then requests[win]:close() end
  requests[win] = nil
  if deadlines[win] then deadlines[win]:stop(); deadlines[win]:close(); deadlines[win] = nil end
  local deadline = vim.uv.new_timer()
  deadlines[win] = deadline
  deadline:start(options.timeout_ms, 0, vim.schedule_wrap(function()
    if generations[win] ~= generation then return end
    generations[win] = nil
    if requests[win] and not requests[win]:is_closing() then requests[win]:close() end
    requests[win] = nil
    deadline:stop(); deadline:close(); deadlines[win] = nil
    fail(win, bufnr, tick, "render request timed out")
  end))

  local sock_path = get_socket_path()

  -- Replies can be cancelled before delivery: Base64 has no orphaned SHM lifetime.
  local flags = 4
  if background == "light" then flags = flags + 1 end            -- FLAG_THEME_LIGHT
  if vim.env.TMUX then flags = flags + 2 end                           -- FLAG_TMUX

  local name = vim.api.nvim_buf_get_name(bufnr)
  local ext = vim.fn.fnamemodify(name, ":e"):lower()
  local binary=({zip=true,tar=true,jar=true,whl=true,tgz=true,tbz2=true,txz=true,tzst=true,png=true})[ext]
  local command=binary and 4 or 8
  local prefix = binary and "" or ext .. "\0"
  local payload
  if binary then
    payload = name
  else
    local count = vim.api.nvim_buf_line_count(bufnr)
    -- The editor's total includes at most one final EOL that IXPC omits.
    if vim.api.nvim_buf_get_offset(bufnr, count) - 1 <= max_payload - #prefix then
      payload = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    end
  end
  local payload_len = payload and #prefix + #payload
  if not payload_len or payload_len > max_payload then
    deadline:stop(); deadline:close(); deadlines[win] = nil
    fail(win, bufnr, tick, "buffer exceeds request limit")
    return
  end

  local header = pack_u32_le(0x49585043) ..    -- MAGIC
                 pack_u16_le(1) ..             -- VERSION
                 pack_u16_le(command) ..             -- render/decorate buffer
                 pack_u32_le(bufnr) ..         -- req_id_lo
                 pack_u32_le(tick) ..          -- req_id_hi
                 pack_u32_le(flags) ..         -- flags
                 pack_u32_le(payload_len) ..   -- payload_len
                 pack_u16_le(cols) ..          -- cols
                 pack_u16_le(rows) ..          -- rows
                 pack_u16_le(cell_w) .. -- cell_w
                 pack_u16_le(cell_h)    -- cell_h

  connect_daemon(sock_path, function(err, pipe)
    if err or not pipe then
      if deadlines[win] == deadline then deadline:stop(); deadline:close(); deadlines[win] = nil end
      vim.schedule(function()
        if generations[win] ~= generation then return end
        fail(win, bufnr, tick, "cannot connect to daemon: " .. tostring(err))
      end)
      return
    end
    if generations[win] ~= generation then pipe:close(); return end
    requests[win] = pipe
    local rx_chunks = {}
    local total_read = 0
    local expected_len = nil
    local apc_len = nil
    local rejected = false

    local function failed(message)
      if not pipe:is_closing() then pipe:close() end
      if generations[win] ~= generation then return end
      requests[win] = nil
      if deadlines[win] == deadline then deadline:stop(); deadline:close(); deadlines[win] = nil end
      vim.schedule(function()
        if generations[win] ~= generation then return end
        fail(win, bufnr, tick, message)
      end)
    end
    pipe:read_start(function(read_err, chunk)
      if generations[win] ~= generation then return end
      if read_err or not chunk then
        failed(tostring(read_err or "incomplete response"))
        return
      end

      table.insert(rx_chunks, chunk)
      total_read = total_read + #chunk
      if total_read > max_payload + 32 then failed("response exceeds limit"); return end

      if not expected_len and total_read >= 32 then
        local full_prefix = table.concat(rx_chunks)
        local resp_payload_len = unpack_u32_le(full_prefix, 21)
        apc_len = unpack_u32_le(full_prefix, 17)
        local magic = unpack_u32_le(full_prefix, 1)
        local version = unpack_u16_le(full_prefix, 5)
        local reply_command = unpack_u16_le(full_prefix, 7)
        rejected = reply_command == 0xC000 + command
        if unpack_u32_le(full_prefix, 9) ~= bufnr or unpack_u32_le(full_prefix, 13) ~= tick or magic ~= 0x49585043 or version ~= 1 or (reply_command ~= 0x8000 + command and not rejected) or resp_payload_len > max_payload or apc_len > resp_payload_len or (rejected and (apc_len ~= 0 or resp_payload_len > 1024)) then
          failed("invalid render response"); return
        end
        expected_len = 32 + resp_payload_len
      end

      if expected_len and total_read > expected_len then failed("trailing response bytes"); return end
      if expected_len and total_read == expected_len then
        pipe:read_stop()
        pipe:close()

        requests[win] = nil
        local full_buf = table.concat(rx_chunks)
        if rejected then
          local message = full_buf:sub(33, 1056):gsub("%s+$", "")
          failed(message ~= "" and message or "render request failed")
          return
        end
        vim.schedule(function()
          if deadlines[win] == deadline then deadline:stop(); deadline:close(); deadlines[win] = nil end
          if not vim.api.nvim_buf_is_valid(bufnr) then return end
          if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick or generations[win] ~= generation or buffer_enabled[bufnr] == false then return end
          if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= bufnr then return end
          if vim.api.nvim_win_get_width(win) ~= cols or vim.api.nvim_win_get_height(win) ~= rows then return end

          if vim.o.background~=background or cached_cell_w~=cell_w or cached_cell_h~=cell_h then return end

          local blocks={};local groups={count=0};local pos=33+apc_len
          local line_count=vim.api.nvim_buf_line_count(bufnr)
          if binary then
            blocks[1]={first=0,last=line_count,lines=virtual_lines(full_buf:sub(pos),groups,win)}
            pos=#full_buf+1
          end
          while pos<=#full_buf do
            if pos+11>#full_buf then failed("truncated decoration header"); return end
            local first=unpack_u32_le(full_buf,pos)
            local last=unpack_u32_le(full_buf,pos+4)
            local size=unpack_u32_le(full_buf,pos+8);pos=pos+12
            if size>#full_buf-pos+1 or first>=line_count or last<=first then failed("invalid decoration block"); return end
            blocks[#blocks+1]={first=first,last=math.min(last,line_count),lines=virtual_lines(full_buf:sub(pos,pos+size-1),groups,win)}
            pos=pos+size
          end
          if apc_len > 0 and #vim.api.nvim_list_uis() > 0 then
            vim.api.nvim_ui_send(full_buf:sub(33, 32 + apc_len))
          end
          if frames[win] and frames[win].ns and vim.api.nvim_buf_is_valid(frames[win].bufnr) then vim.api.nvim_buf_clear_namespace(frames[win].bufnr,frames[win].ns,0,-1) end
          errors[win] = nil
          frames[win]={bufnr=bufnr,tick=tick,cols=cols,blocks=blocks,graphics_bytes=apc_len,rows=rows,background=background,cell_w=cell_w,cell_h=cell_h}
          decorate(win)
          vim.api.nvim__redraw({win=win,valid=false})
        end)
      end
    end)

    local writing, write_err = pipe:write({ header, prefix, payload }, function(err)
      if err then failed(tostring(err)) end
    end)
    if not writing then failed(tostring(write_err)) end
  end, function() return generations[win] == generation and deadlines[win] == deadline end)
end

function M.clear(bufnr)
  local current = frames[vim.api.nvim_get_current_win()]
  bufnr = bufnr or (current and current.bufnr) or vim.api.nvim_get_current_buf()
  for win, err in pairs(errors) do
    if err.source == bufnr then errors[win] = nil end
  end
  for win, frame in pairs(frames) do
    if frame.bufnr == bufnr then
      discard(win)
    end
  end
  sync_source_highlights(bufnr)
  for win, pipe in pairs(requests) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) == bufnr then
      generations[win] = nil
      if not pipe:is_closing() then pipe:close() end
      requests[win] = nil
    end
  end
  for win, deadline in pairs(deadlines) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) == bufnr then
      generations[win] = nil
      deadline:stop(); deadline:close(); deadlines[win] = nil
    end
  end
  vim.cmd("redraw")
end

function M.toggle(bufnr)
  local frame = frames[vim.api.nvim_get_current_win()]
  bufnr = bufnr or (frame and frame.bufnr) or vim.api.nvim_get_current_buf()
  if buffer_enabled[bufnr] == false then
    buffer_enabled[bufnr] = true
    M.render(bufnr)
  else
    buffer_enabled[bufnr] = false
    M.clear(bufnr)
  end
end

function M.setup(opts)
  assert(vim.api.nvim_ui_send, "ii: Neovim 0.12+ is required for ordered terminal graphics output")
  opts = opts or {}
  local debounce_ms = opts.debounce_ms or 20
  options.executable = opts.executable or options.executable
  options.timeout_ms = opts.timeout_ms or options.timeout_ms
  if opts.socket_path then vim.g.ii_socket_path = opts.socket_path end
  assert(options.timeout_ms > 0 and debounce_ms >= 0, "ii: invalid timer settings")

  local augroup = vim.api.nvim_create_augroup("IiAutoRender", { clear = true })
  local function refresh(ev)
      local bufnr = ev.buf and ev.buf>0 and ev.buf or vim.api.nvim_get_current_buf()
      local current_win=vim.api.nvim_get_current_win()
      if frames[current_win] and frames[current_win].bufnr~=bufnr then
        local previous=frames[current_win]
        if previous.ns and vim.api.nvim_buf_is_valid(previous.bufnr) then vim.api.nvim_buf_clear_namespace(previous.bufnr,previous.ns,0,-1) end
        frames[current_win]=nil
        yank_preview[current_win]=nil
        sync_source_highlights(previous.bufnr)
        view_mode(current_win,false);saved[current_win]=nil
      end
      local ft = vim.bo[bufnr].filetype
      local ext = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr),":e"):lower()
      if not ({markdown=true,md=true,mdx=true,quarto=true,qmd=true,rmd=true})[ft]
        and not ({md=true,markdown=true,mdx=true,qmd=true,rmd=true,html=true,htm=true,ipynb=true,plotly=true,vl=true,vega=true,["vega-lite"]=true,json=true,csv=true,tsv=true,tex=true,latex=true,chem=true,mhchem=true,mmd=true,mermaid=true,dot=true,gv=true,svg=true,typ=true,typst=true,zip=true,tar=true,jar=true,whl=true,tgz=true,tbz2=true,txz=true,tzst=true,png=true})[ext] then return end
      if frames[vim.api.nvim_get_current_win()] and frames[vim.api.nvim_get_current_win()].tick~=vim.api.nvim_buf_get_changedtick(bufnr) then decorate(vim.api.nvim_get_current_win()) end
      if vim.fn.mode():match("^[iR]") then return end
      if buffer_enabled[bufnr] == false then return end
      ev.buf = bufnr
      local timer = timers[ev.buf] or vim.uv.new_timer()
      timers[ev.buf] = timer
      timer:stop()
      timer:start(debounce_ms, 0, vim.schedule_wrap(function()
        if vim.api.nvim_buf_is_valid(ev.buf) then
          local windows = {}
          for _, win in ipairs(vim.fn.win_findbuf(ev.buf)) do windows[win]=true end
          for win,frame in pairs(frames) do if frame.bufnr==ev.buf then windows[win]=true end end
          for win in pairs(windows) do if vim.api.nvim_win_is_valid(win) then M.render(ev.buf,win,ev.event=="ColorScheme") end end
        end
      end))
    end
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "FileType", "BufWritePost", "TextChanged", "InsertLeave", "WinResized", "ColorScheme" }, {group=augroup,callback=refresh})
  vim.schedule(function() refresh({buf=vim.api.nvim_get_current_buf(),event="Setup"}) end)
  vim.api.nvim_create_autocmd("ModeChanged", { group = augroup, callback = function()
    local event = vim.v.event
    if event.old_mode and editing_source(event.old_mode) == editing_source(event.new_mode) then return end
    for win in pairs(frames) do decorate(win) end
    vim.cmd("redraw!")
  end })
  vim.api.nvim_create_autocmd("TextYankPost", { group = augroup, callback = function(ev)
    if vim.v.event.operator ~= "y" then return end
    local win = vim.api.nvim_get_current_win()
    local frame = frames[win]
    if not frame or frame.bufnr ~= ev.buf then return end

    -- Expose the source while Neovim's yank highlight is drawn beneath the overlay.
    local token = {}
    yank_preview[win] = token
    vim.schedule(function()
      if yank_preview[win] == token then decorate(win) end
    end)
    vim.defer_fn(function()
      if yank_preview[win] ~= token then return end
      yank_preview[win] = nil
      decorate(win)
    end, 150)
  end })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    callback = function(ev)
      M.clear(ev.buf)
      if timers[ev.buf] then timers[ev.buf]:stop(); timers[ev.buf]:close(); timers[ev.buf] = nil end
      buffer_enabled[ev.buf] = nil
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      local win = tonumber(ev.match)
      yank_preview[win] = nil
      generations[win] = nil
      local frame=frames[win]
      if frame and frame.ns and vim.api.nvim_buf_is_valid(frame.bufnr) then vim.api.nvim_buf_clear_namespace(frame.bufnr,frame.ns,0,-1) end
      frames[win] = nil
      errors[win] = nil
      if frame then sync_source_highlights(frame.bufnr) end
      saved[win]=nil
      if requests[win] and not requests[win]:is_closing() then requests[win]:close() end
      requests[win] = nil
      if deadlines[win] then deadlines[win]:stop(); deadlines[win]:close(); deadlines[win] = nil end
    end,
  })



end

-- Register standard commands and aliases
vim.api.nvim_create_user_command("IiRender", function() M.render(nil,nil,true) end, { desc = "Render buffer with ii coprocessor" })
vim.api.nvim_create_user_command("IiToggle", function() M.toggle() end, { desc = "Toggle ii KGP rendering" })
vim.api.nvim_create_user_command("IiClear", function() M.clear() end, { desc = "Clear ii extmarks" })
vim.api.nvim_create_user_command("PixxRender", function() M.render(nil,nil,true) end, { desc = "Render buffer with ii coprocessor" })
vim.api.nvim_create_user_command("PixxToggle", function() M.toggle() end, { desc = "Toggle ii KGP rendering" })
vim.api.nvim_create_user_command("PixxClear", function() M.clear() end, { desc = "Clear ii extmarks" })

--- Current window render state, suitable for diagnostics and health checks.
function M.status(win)
  win = win or vim.api.nvim_get_current_win()
  local frame = frames[win]
  local err = errors[win]
  return { pending = deadlines[win] ~= nil, blocks = frame and #frame.blocks or 0, graphics_bytes = frame and frame.graphics_bytes or 0, source = frame and frame.bufnr or nil,
    source_tick = frame and frame.tick or nil, cols = frame and frame.cols or nil,
    last_error = err and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == err.source and err.message or nil }
end

return M
