local util = require("remote-mirror.util")

local M = {}

local defaults = {
  upload_on_save = true,
  debounce_ms = 200,
  watch = true,
  watch_debounce_ms = 300,
  ssh_command = "ssh",
  rsync_command = "rsync",
  rsync_args = { "-az" },
  default_ignore = {
    "node_modules/",
    "target/",
    "dist/",
    "build/",
    ".cache/",
    "*.log",
  },
}

local function assert_string(options, key)
  assert(type(options[key]) == "string" and options[key] ~= "", ("remote-mirror: %s is required"):format(key))
end

function M.normalize(options)
  options = vim.tbl_deep_extend("force", defaults, options or {})
  assert_string(options, "host")
  assert_string(options, "remote_root")

  options.name = options.name or options.remote_root:match("([^/]+)/*$") or options.host
  local mirror_root = options.mirror_root
    or util.join(vim.fn.stdpath("data"), "remote-mirror", options.name)

  options.mirror_root = vim.fs.normalize(mirror_root)
  options.source_root = vim.fs.normalize(options.source_root or util.join(mirror_root, "source"))
  options.state_root = vim.fs.normalize(options.state_root or util.join(mirror_root, ".remote-state"))
  options.tree_root = vim.fs.normalize(options.tree_root or util.join(mirror_root, ".remote-tree"))
  options.remote_root = options.remote_root:gsub("/+$", "")

  assert(type(options.rsync_args) == "table", "remote-mirror: rsync_args must be a table")
  assert(type(options.default_ignore) == "table", "remote-mirror: default_ignore must be a table")
  assert(options.debounce_ms >= 0, "remote-mirror: debounce_ms must be non-negative")
  assert(options.watch_debounce_ms >= 0, "remote-mirror: watch_debounce_ms must be non-negative")

  return options
end

return M
