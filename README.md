# ii.nvim

Requires Neovim 0.12+ and a terminal with Kitty Unicode placeholders. Configure:

With lazy.nvim, add this spec for a local checkout:

```lua
return {
  dir = vim.fn.expand("~/src/ii/plugins/ii.nvim"),
  name = "ii.nvim",
  main = "ii",
  ft = { "markdown", "markdown.mdx", "mdx", "quarto", "rmd" },
  cmd = { "IiRender", "IiToggle", "IiClear" },
  opts = { executable = "ii" },
}
```

Install a matching ii executable on PATH. After publishing the plugin as a
separate repository, replace the dir field with its GitHub slug as the first
entry. Use :IiRender to open a preview explicitly, including for notebooks.

The original Neovim buffer remains active in every mode. The adapter installs no
keymaps, injects no input and never changes editor modes or source bytes. In Normal
mode window-scoped persistent extmarks conceal source ranges and display prepared virtual
lines. Insert, Replace, Visual and Select expose the original source. The adapter
also exposes it briefly after a yank so Neovim can draw its own highlight.
The rendered view uses the complete window: number/sign/fold gutters and winbar
are hidden, source wrapping and folding are disabled. Source view and
`IiClear` restore the original window options. `IiClear` removes decorations; `IiToggle`
switches rendering.

DecorateBuffer (IXPC command 8) carries the extension, a zero separator and unsaved
buffer bytes. Its response contains graphics and source-anchored ANSI blocks. Notebook cells
retain their original JSON ranges instead of attaching the entire notebook to
the first source row. Rendered rows use available native source anchors; only
overflow within a block uses virtual lines. A block consisting entirely of
graphics uses its closing source line as a single anchor. Scrolling to a
source line inside that block displays the image from its first row.
While a rendered view is active, ii suspends Tree-sitter highlighting for that
buffer so Tree-sitter cannot hide source rows that carry rendered content.
Highlighting resumes in Insert/Replace mode or when the last rendered view closes.
Archives and PNG use RenderFile to preserve binary bytes. Plotly, Vega-Lite,
notebook, CSV/TSV, TeX, mhchem, Mermaid, DOT, SVG and Markdown share the complete
document renderer with CLI and Yazi. Archives display a native directory tree.

ANSI is converted to virtual lines once per completed response. Decorations are installed when a frame arrives or the editor changes mode.
Mouse motion and scrolling perform no Lua redraw callbacks, parsing, compilation or IPC. Graphics use nvim_ui_send. Stale responses
are rejected by source tick, request generation and window geometry.

`require('ii').status(win)` reports pending work, the current frame, and `last_error`
for the current buffer. A successful render or `IiClear` clears the error.
`python3 showcase/checks/nvim_ui.py --binary target/release/ii` runs a real TUI in a PTY
and checks native buffers, unchanged keymaps, i/Esc editing, 80 native notebook
scroll steps, redraws and format
routing, including chemistry and archive trees.

The core's format limitations still apply. This does not implement a Python/R
kernel, full Typst or full Vega/Plotly specifications, or every Markdown extension.


For lazy.nvim, every supported filetype must be a load trigger (the renderer cannot
handle an unopened plugin). Use the same complete list:

```lua
{
  name = 'ii.nvim', dir = '/path/to/ii/plugins/ii.nvim',
  ft = {'markdown','mdx','quarto','rmd','html','ipynb','tex','latex','typst',
    'mermaid','mmd','dot','gv','svg','png','csv','tsv','plotly','vl','vegalite',
    'chem','mhchem','zip','jar','whl','tar','tgz','tbz2','txz','tzst'},
  opts = {executable = '/path/to/ii/target/release/ii'},
}
```
