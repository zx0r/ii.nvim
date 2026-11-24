# ii.nvim

Terminal graphical coprocessor integration for Neovim. Renders math formulas, Mermaid diagrams, Vega/Plotly charts, SVGs, and Jupyter Notebooks inline using the Kitty Graphics Protocol (KGP) and Sixel.

Requires [ii](https://github.com/zx0r/ii#installation) binary on `PATH` and a terminal emulator with Kitty Graphics Protocol support (Kitty, Ghostty, WezTerm).

---

## Features

- **Zero-Latency IPC**: Connects asynchronously via Unix domain socket (`IXPC v1`) without blocking Neovim's main loop.
- **Ordered Frame Delivery**: Uses `nvim_ui_send` on Neovim 0.12+ for ordered rendering, with progressive TTY fallback for Neovim 0.10 and 0.11.
- **Synchronized Scrolling**: Computes precise line-to-cell geometry via C FFI (`TIOCGWINSZ`) with tmux split protection.
- **Seamless Editing**: Automatically conceals raw source markup and exposes underlying text during Insert mode or visual yank.

---

## Installation

### lazy.nvim (Recommended)

```lua
{
  "zx0r/ii.nvim",
  ft = {
    "markdown", "markdown.mdx", "md", "mdx", "quarto", "qmd", "rmd", "ipynb",
    "html", "htm", "tex", "plaintex", "latex", "typst", "typ",
    "mermaid", "mmd", "dot", "gv", "svg", "svgz", "png", "csv", "tsv",
    "plotly", "vl", "vega", "vega-lite", "chem", "mhchem",
    "zip", "jar", "whl", "tar", "tgz", "tbz2", "txz", "tzst",
  },
  cmd = { "Ii", "IiRender", "IiToggle", "IiClear", "IiPreview" },
  keys = {
    { "<leader>pr", "<cmd>IiRender<cr>",  desc = "ii: Render buffer" },
    { "<leader>pt", "<cmd>IiToggle<cr>",  desc = "ii: Toggle KGP rendering" },
    { "<leader>pc", "<cmd>IiClear<cr>",   desc = "ii: Clear decorations" },
    { "<leader>pp", "<cmd>IiPreview<cr>", desc = "ii: Instant preview" },
  },
  opts = {
    -- 10ms debounce tuned for Apple ProMotion 120Hz displays (8.33ms frame window)
    debounce_ms = 10,
    -- IPC deadline timeout for complex multi-node vector charts
    timeout_ms = 3000,
  },
}
```

### rocks.nvim / LuaRocks

```sh
:Rocks install ii.nvim
```

---

## Commands

| Command | Description |
| :--- | :--- |
| `:IiToggle [bufnr]` | Toggle graphical overlay for current or targeted buffer |
| `:IiRender [bufnr]` | Force instantaneous render pass |
| `:IiClear [bufnr]` | Discard active graphics and clear all extmarks |
| `:IiPreview [bufnr]` | Trigger single-pass preview without persistent auto-render |
| `:Ii <subcommand>` | Dispatcher with auto-completion (`toggle`, `render`, `clear`, `preview`) |

---

## Configuration

Default options passed to `setup(opts)`:

```lua
require("ii").setup({
  -- Debounce delay in milliseconds before scheduling render pass
  debounce_ms = 10,

  -- Maximum timeout for IPC response from the daemon
  timeout_ms = 3000,

  -- Custom Unix socket path (defaults to $XDG_RUNTIME_DIR/ii/ii.sock or /tmp/ii-$UID/ii.sock)
  socket_path = nil,

  -- Path to ii binary if not found on standard PATH
  executable = "ii",
})
```
