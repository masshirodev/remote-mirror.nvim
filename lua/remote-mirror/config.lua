local util = require("remote-mirror.util")

local M = {}

local defaults = {
  upload_on_save = true,
  debounce_ms = 200,
  watch = true,
  watch_debounce_ms = 300,
  poll_on_focus = true,
  poll_interval_ms = 0,
  poll_auto_pull = true,
  ssh_connect_timeout = 10,
  remote_sudo = false,
  remote_sudo_auth = "passwordless",
  ssh_command = "ssh",
  ssh_args = {},
  transfer = "rsync",
  rsync_command = "rsync",
  rsync_args = { "-az" },
  scp_command = "scp",
  scp_args = {},
  remote_find_command = "find",
  remote_stat_command = "stat",
  remote_sha256sum_command = "sha256sum",
  remote_du_command = "du",
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
  local overrides = options or {}
  if options and options.port == "" then
    options = vim.tbl_deep_extend("force", {}, options)
    options.port = nil
  end
  options = vim.tbl_deep_extend("force", defaults, options or {})
  for _, key in ipairs({ "ssh_args", "rsync_args", "scp_args", "default_ignore" }) do
    if overrides[key] ~= nil then
      options[key] = vim.deepcopy(overrides[key])
    end
  end
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
  options.port = options.port and tonumber(options.port) or nil

  if options.port then
    assert(options.port % 1 == 0, "remote-mirror: port must be an integer")
    assert(options.port >= 1 and options.port <= 65535, "remote-mirror: port must be between 1 and 65535")
  end
  if options.user ~= nil then
    assert(
      type(options.user) == "string" and options.user:match("^[%w._-]+$"),
      ("remote-mirror: user contains unsupported characters: %s; use the login name only, without a host"):format(
        vim.inspect(options.user)
      )
    )
  end
  if options.ssh_config_file ~= nil then
    assert(
      type(options.ssh_config_file) == "string" and options.ssh_config_file:sub(1, 1) == "/",
      "remote-mirror: ssh_config_file must be an absolute path"
    )
  end
  assert(
    options.auth == nil or options.auth == "ssh" or options.auth == "password",
    "remote-mirror: auth must be ssh or password"
  )
  assert(
    options.transfer == "rsync" or options.transfer == "scp",
    "remote-mirror: transfer must be rsync or scp"
  )
  assert(type(options.remote_sudo) == "boolean", "remote-mirror: remote_sudo must be a boolean")
  assert(
    options.remote_sudo_auth == "passwordless" or options.remote_sudo_auth == "password",
    "remote-mirror: remote_sudo_auth must be passwordless or password"
  )
  assert(
    not options.remote_sudo or options.transfer == "rsync",
    "remote-mirror: remote_sudo requires transfer = rsync; SCP cannot privilege its destination"
  )
  for _, key in ipairs({
    "ssh_command",
    "rsync_command",
    "scp_command",
    "remote_find_command",
    "remote_stat_command",
    "remote_sha256sum_command",
    "remote_du_command",
  }) do
    assert_string(options, key)
  end
  for _, key in ipairs({ "remote_find_command", "remote_stat_command", "remote_sha256sum_command", "remote_du_command" }) do
    assert(
      options[key]:match("^[%w._/%-]+$"),
      ("remote-mirror: %s must be an executable name or absolute path"):format(key)
    )
  end
  for _, key in ipairs({ "ssh_args", "rsync_args", "scp_args" }) do
    assert(type(options[key]) == "table", ("remote-mirror: %s must be a table"):format(key))
    for _, argument in ipairs(options[key]) do
      assert(type(argument) == "string", ("remote-mirror: %s must contain strings"):format(key))
    end
  end
  assert(type(options.default_ignore) == "table", "remote-mirror: default_ignore must be a table")
  assert(options.debounce_ms >= 0, "remote-mirror: debounce_ms must be non-negative")
  assert(options.watch_debounce_ms >= 0, "remote-mirror: watch_debounce_ms must be non-negative")
  assert(options.poll_interval_ms >= 0, "remote-mirror: poll_interval_ms must be non-negative")
  assert(options.ssh_connect_timeout >= 1, "remote-mirror: ssh_connect_timeout must be positive")

  return options
end

return M
