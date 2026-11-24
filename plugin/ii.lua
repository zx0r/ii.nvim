-- ii.nvim: terminal graphical coprocessor commands and autocommands
if vim.g.loaded_ii == 1 then
  return
end
vim.g.loaded_ii = 1

local ii = require("ii")

-- Core user commands
vim.api.nvim_create_user_command("IiToggle", function(opts)
  local bufnr = tonumber(opts.args) or vim.api.nvim_get_current_buf()
  ii.toggle(bufnr)
end, {
  desc = "Toggle ii graphical rendering for buffer",
  nargs = "?",
})

vim.api.nvim_create_user_command("IiRender", function(opts)
  local bufnr = tonumber(opts.args) or vim.api.nvim_get_current_buf()
  ii.render(bufnr)
end, {
  desc = "Force ii graphical render for buffer",
  nargs = "?",
})

vim.api.nvim_create_user_command("IiClear", function(opts)
  local bufnr = tonumber(opts.args) or vim.api.nvim_get_current_buf()
  ii.clear(bufnr)
end, {
  desc = "Clear ii graphical overlay and decorations",
  nargs = "?",
})

vim.api.nvim_create_user_command("IiPreview", function(opts)
  local bufnr = tonumber(opts.args) or vim.api.nvim_get_current_buf()
  ii.render(bufnr, vim.api.nvim_get_current_win(), true)
end, {
  desc = "Trigger instantaneous ii preview pass",
  nargs = "?",
})

-- Unified dispatcher command
vim.api.nvim_create_user_command("Ii", function(opts)
  local cmd = opts.fargs[1] or "toggle"
  local target_buf = tonumber(opts.fargs[2]) or vim.api.nvim_get_current_buf()

  if cmd == "toggle" then
    ii.toggle(target_buf)
  elseif cmd == "render" then
    ii.render(target_buf)
  elseif cmd == "clear" then
    ii.clear(target_buf)
  elseif cmd == "preview" then
    ii.render(target_buf, vim.api.nvim_get_current_win(), true)
  else
    vim.notify("ii: unknown subcommand '" .. cmd .. "'. Expected: toggle, render, clear, preview", vim.log.levels.ERROR)
  end
end, {
  desc = "Control ii graphical coprocessor",
  nargs = "*",
  complete = function(_, line)
    local subcommands = { "toggle", "render", "clear", "preview" }
    local args = vim.split(line, "%s+")
    if #args <= 2 then
      return vim.tbl_filter(function(item)
        return vim.startswith(item, args[2] or "")
      end, subcommands)
    end
    return {}
  end,
})
