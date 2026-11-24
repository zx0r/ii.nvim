package = "ii.nvim"
version = "scm-1"
source = {
  url = "git+https://github.com/zx0r/ii.nvim.git",
}
description = {
  summary = "Terminal graphical coprocessor integration for Neovim",
  detailed = [[
    ii.nvim integrates ii (intelligent inline graphical renderer) into Neovim,
    providing high-performance, ordered Kitty Graphics Protocol and Sixel inline
    rendering with automatic window decoration and synchronized scrolling.
  ]],
  homepage = "https://github.com/zx0r/ii",
  license = "MIT OR Apache-2.0",
}
dependencies = {
  "lua >= 5.1",
}
build = {
  type = "builtin",
  modules = {
    ["ii"] = "lua/ii/init.lua",
  },
  copy_directories = {
    "plugin",
    "ftdetect",
    "doc",
  },
}
