if vim.g.loaded_remote_mirror then
  return
end
vim.g.loaded_remote_mirror = true

require("remote-mirror").setup()
