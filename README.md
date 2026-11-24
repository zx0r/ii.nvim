# ii.nvim

Preview documents in Neovim 0.12+. Install [ii](https://github.com/zx0r/ii#installation) first and put it on `PATH`. Use a terminal with Kitty graphics support.

## Installation

Add this spec to `lazy.nvim`:

```lua
return {
  "zx0r/ii.nvim",
  main = "ii",
  lazy = false,
  opts = {},
}
```

Open a Markdown file or notebook. Use `:IiToggle` to switch between preview and source.
