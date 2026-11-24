-- Plugin loader for ii.nvim
if vim.g.loaded_ii == 1 then
  return
end
vim.g.loaded_ii = 1

require("ii")
