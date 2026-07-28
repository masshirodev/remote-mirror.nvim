local Config = require("remote-mirror.config")
local Core = require("remote-mirror.core")
local Ignore = require("remote-mirror.ignore")
local Registry = require("remote-mirror.registry")
local Transport = require("remote-mirror.transport")
local util = require("remote-mirror.util")

local M = {}
M.__index = M

local workspace_keys = {
  "name",
  "host",
  "user",
  "port",
  "auth",
  "transfer",
  "remote_sudo",
  "ssh_config_file",
  "ssh_command",
  "ssh_args",
  "rsync_command",
  "rsync_args",
  "scp_command",
  "scp_args",
  "remote_find_command",
  "remote_stat_command",
  "remote_sha256sum_command",
  "remote_du_command",
  "remote_root",
  "mirror_root",
  "source_root",
  "state_root",
  "tree_root",
  "default_ignore",
}

function M.new(options)
  options = options or {}
  local registry_path = options.registry_path
    or util.join(vim.fn.stdpath("data"), "remote-mirror", "workspaces.json")
  local manager = setmetatable({
    options = options,
    registry = Registry.new(registry_path):load(),
    current = nil,
    credentials = {},
  }, M)

  for _, workspace in ipairs(options.workspaces or {}) do
    manager.registry:add(manager:workspace_options(workspace))
  end
  return manager
end

function M:workspace_options(workspace)
  local options = vim.deepcopy(self.options)
  options.workspaces = nil
  options.registry_path = nil
  for _, key in ipairs(workspace_keys) do
    if workspace[key] ~= nil then
      options[key] = workspace[key]
    end
  end
  return Config.normalize(options)
end

function M:add(workspace)
  local config = self:workspace_options(workspace)
  self.registry:add(config)
  return config
end

function M:update_connection(name, connection)
  local workspace = assert(self.registry.workspaces[name], "remote-mirror: unknown workspace " .. name)
  local updated = vim.tbl_deep_extend("force", {}, workspace, connection)
  updated.user = connection.user
  updated.port = connection.port
  updated.auth = connection.auth
  updated.transfer = connection.transfer or workspace.transfer or "rsync"
  return self:add(updated)
end

function M:set_password(name, password)
  if password and password ~= "" then
    self.credentials[name] = password
  else
    self.credentials[name] = nil
  end
end

function M:has_password(name)
  return self.credentials[name] ~= nil
end

function M:resolve_ssh(host, ssh_command)
  return require("remote-mirror.ssh_config").resolve(
    ssh_command or self.options.ssh_command or "ssh",
    host
  )
end

function M:list()
  return self.registry:list()
end

function M:remove(name)
  assert(self.registry.workspaces[name], "remote-mirror: unknown workspace " .. name)
  assert(self.connecting ~= name, "remote-mirror: cannot delete a workspace while it is connecting")
  if self.current and self.current.config.name == name then
    self:_deactivate()
  end
  self.credentials[name] = nil
  self.registry:remove(name)
end

function M:mirror_path(name)
  local workspace = assert(self.registry.workspaces[name], "remote-mirror: unknown workspace " .. name)
  return self:workspace_options(workspace).mirror_root
end

-- Recursive deletion only ever touches the plugin-owned layout: every managed
-- path must sit inside the mirror directory, which must not be the home
-- directory, the filesystem root, or an ancestor of where Neovim is working.
local function removable_mirror_root(config)
  local root = vim.fs.normalize(config.mirror_root):gsub("/+$", "")
  assert(root ~= "" and root ~= "/", "remote-mirror: refusing to delete the filesystem root")
  local home = vim.fs.normalize(vim.fn.expand("~")):gsub("/+$", "")
  assert(root ~= home, "remote-mirror: refusing to delete the home directory")

  for _, key in ipairs({ "source_root", "state_root", "tree_root" }) do
    local path = vim.fs.normalize(config[key]):gsub("/+$", "")
    assert(
      path:sub(1, #root + 1) == root .. "/",
      ("remote-mirror: %s is outside %s; delete it manually"):format(key, root)
    )
  end

  local cwd = vim.fs.normalize(vim.fn.getcwd()):gsub("/+$", "")
  assert(
    cwd ~= root and cwd:sub(1, #root + 1) ~= root .. "/",
    "remote-mirror: leave the mirror directory before deleting it"
  )
  return root
end

function M:reset_mirror(name)
  local workspace = assert(self.registry.workspaces[name], "remote-mirror: unknown workspace " .. name)
  assert(
    not self.current or self.current.config.name ~= name,
    "remote-mirror: disconnect " .. name .. " before deleting its mirror"
  )
  assert(self.connecting ~= name, "remote-mirror: " .. name .. " is connecting")

  local root = removable_mirror_root(self:workspace_options(workspace))
  if vim.fn.isdirectory(root) == 0 then
    return { path = root, existed = false }
  end
  assert(vim.fn.delete(root, "rf") == 0, "remote-mirror: could not delete " .. root)
  return { path = root, existed = true }
end

function M:has_local_mirror(name)
  local workspace = assert(self.registry.workspaces[name], "remote-mirror: unknown workspace " .. name)
  local config = self:workspace_options(workspace)
  if util.is_file(util.join(config.state_root, "state.json")) then
    return true
  end
  local scan = vim.uv.fs_scandir(config.source_root)
  return scan ~= nil and vim.uv.fs_scandir_next(scan) ~= nil
end

function M:get(name)
  return self.registry.workspaces[name]
end

-- Reports a mirror that was built for a different host or remote path, which
-- happens when a workspace name is reused for another endpoint.
function M:mirror_conflict(name)
  local workspace = self.registry.workspaces[name]
  if not workspace then
    return nil
  end
  local ok, config = pcall(self.workspace_options, self, workspace)
  if not ok then
    return nil
  end
  local state = require("remote-mirror.state").new(config):load()
  if not state.foreign then
    return nil
  end
  return {
    host = state.foreign.host,
    remote_root = state.foreign.remote_root,
    mirror_root = config.mirror_root,
  }
end

function M:_build_core(name)
  local workspace = assert(self.registry.workspaces[name], "remote-mirror: unknown workspace " .. name)
  local conflict = self:mirror_conflict(name)
  if conflict then
    error(
      ("remote-mirror: the mirror at %s belongs to %s:%s; rename this workspace or remove that directory"):format(
        conflict.mirror_root,
        conflict.host,
        conflict.remote_root
      ),
      0
    )
  end
  local config = self:workspace_options(workspace)
  local resolved = self:resolve_ssh(config.host, config.ssh_command)
  config.ssh_config_file = config.ssh_config_file or resolved.config_file
  if config.auth == "password" then
    config._password = assert(
      self.credentials[name],
      "remote-mirror: password required; edit or reconnect the workspace"
    )
  end
  return Core.new(config, {
    transport = Transport.new(config, require("remote-mirror.async").runner),
  })
end

function M:_activate(core)
  if self.current then
    self.current:detach()
  else
    self.previous_cwd = vim.fn.getcwd()
  end
  core:start_watcher()
  core:start_poll_timer()
  self.current = core
  vim.cmd.cd(vim.fn.fnameescape(core.config.source_root))
  return core
end

function M:_deactivate()
  local core = self.current
  if not core then
    return
  end
  core:detach()
  self.current = nil

  local previous = self.previous_cwd
  self.previous_cwd = nil
  if previous and vim.fn.isdirectory(previous) == 1 then
    vim.cmd.cd(vim.fn.fnameescape(previous))
  end
  return core
end

function M:disconnect(force)
  local core = assert(self.current, "remote-mirror: no workspace is connected")
  assert(not self.connecting, "remote-mirror: a workspace connection is in progress")

  local pending = vim.tbl_count(core.pending)
  if not force then
    assert(
      not core.operation_active and #core.operation_queue == 0,
      "remote-mirror: a workspace operation is running; wait for it or use :RemoteMirrorDisconnect!"
    )
    assert(
      pending == 0,
      ("remote-mirror: %d file(s) are waiting to upload; wait for them or use :RemoteMirrorDisconnect!"):format(
        pending
      )
    )
  end

  self:_deactivate()
  return { name = core.config.name, pending = pending }
end

function M:connect(name)
  local workspace = self.registry.workspaces[name]
  assert(workspace, "remote-mirror: unknown workspace " .. name)
  if self.current then
    self.current:stop_watcher()
    self.current:stop_poll_timer()
    self.current = nil
  end

  local config = self:workspace_options(workspace)
  local resolved = self:resolve_ssh(config.host, config.ssh_command)
  config.ssh_config_file = config.ssh_config_file or resolved.config_file
  if config.auth == "password" then
    config._password = assert(
      self.credentials[name],
      "remote-mirror: password required; edit or reconnect the workspace"
    )
  end
  local core = Core.new(config)
  core:ensure_layout()
  core:pull()
  core:start_watcher()
  core:start_poll_timer()
  self.current = core
  vim.cmd.cd(vim.fn.fnameescape(core.config.source_root))
  return core
end

function M:connect_async(name, strategy, callback)
  if type(strategy) == "function" then
    callback = strategy
    strategy = "pull"
  end
  strategy = strategy or "pull"
  assert(
    strategy == "pull" or strategy == "force_pull" or strategy == "force_push",
    "remote-mirror: invalid connect strategy"
  )
  if self.connecting then
    callback(false, "remote-mirror: a workspace connection is already in progress")
    return
  end
  if not self.registry.workspaces[name] then
    callback(false, "remote-mirror: unknown workspace " .. name)
    return
  end

  local ok, core = pcall(self._build_core, self, name)
  if not ok then
    callback(false, core)
    return
  end

  self.connecting = name
  require("remote-mirror.async").run(function()
    core:ensure_layout()
    if strategy == "force_pull" then
      core:force_pull()
    elseif strategy == "force_push" then
      core:force_push()
    else
      core:pull()
    end
    return core
  end, function(connect_ok, result)
    self.connecting = false
    if connect_ok then
      self:_activate(result)
    end
    callback(connect_ok, result)
  end)
end

function M:review_connect_async(name, callback)
  if self.connecting then
    callback(false, "remote-mirror: a workspace connection is already in progress")
    return
  end
  local ok, core = pcall(self._build_core, self, name)
  if not ok then
    callback(false, core)
    return
  end

  self.connecting = name
  require("remote-mirror.async").run(function()
    return core:reconcile_plan()
  end, function(review_ok, plan)
    if not review_ok then
      self.connecting = false
      callback(false, plan)
      return
    end
    self.reviewing = { name = name, core = core, plan = plan }
    callback(true, self.reviewing)
  end)
end

function M:apply_review_async(actions, callback)
  local reviewing = self.reviewing
  if not reviewing then
    callback(false, "remote-mirror: no reviewed connection is pending")
    return
  end
  require("remote-mirror.async").run(function()
    local result = reviewing.core:apply_reconcile(reviewing.plan, actions)
    return { core = reviewing.core, result = result }
  end, function(ok, result)
    self.connecting = false
    self.reviewing = nil
    if ok then
      self:_activate(result.core)
    end
    callback(ok, result)
  end)
end

function M:cancel_review()
  self.reviewing = nil
  self.connecting = false
end

-- Browsing happens before a project root exists, so the caller supplies the
-- root the transport should act on instead of the workspace carrying one.
function M:browsing_transport(workspace, password, remote_root)
  local definition = vim.tbl_extend("force", {}, workspace)
  definition.remote_root = remote_root
  local ok, config = pcall(self.workspace_options, self, definition)
  if not ok then
    return nil, config
  end
  local resolved = self:resolve_ssh(config.host, config.ssh_command)
  config.ssh_config_file = config.ssh_config_file or resolved.config_file
  if config.auth == "password" then
    config._password = password
    if not config._password or config._password == "" then
      return nil, "remote-mirror: password is required"
    end
  end
  return Transport.new(config, require("remote-mirror.async").runner), config
end

function M:browse_remote_async(workspace, password, path, callback)
  local transport, err = self:browsing_transport(workspace, password, "/")
  if not transport then
    callback(false, err)
    return
  end
  require("remote-mirror.async").run(function()
    return transport:list_directory(path)
  end, callback)
end

-- `.remoteignore` belongs to a project root, and while browsing the directory
-- on screen is the candidate root, so its own file is the one being edited.
function M:remote_ignore_at_async(workspace, password, path, callback)
  local transport, err = self:browsing_transport(workspace, password, path)
  if not transport then
    callback(false, err)
    return
  end
  require("remote-mirror.async").run(function()
    return transport:remote_ignore_info()
  end, callback)
end

function M:write_remote_ignore_at_async(workspace, password, path, contents, callback)
  local transport, err = self:browsing_transport(workspace, password, path)
  if not transport then
    callback(false, err)
    return
  end
  require("remote-mirror.async").run(function()
    transport:write_remote_ignore(contents)
    return true
  end, callback)
end

function M:inspect_workspace_async(workspace, password, callback)
  local ok, config = pcall(self.workspace_options, self, workspace)
  if not ok then
    callback(false, config)
    return
  end
  local resolved = self:resolve_ssh(config.host, config.ssh_command)
  config.ssh_config_file = config.ssh_config_file or resolved.config_file
  if config.auth == "password" then
    config._password = password
    if not config._password or config._password == "" then
      callback(false, "remote-mirror: password is required")
      return
    end
  end

  local transport = Transport.new(config, require("remote-mirror.async").runner)
  require("remote-mirror.async").run(function()
    local stats = transport:workspace_stats()
    stats.remote_ignore = transport:remote_ignore_info()
    return stats
  end, callback)
end

function M:estimate_workspace_async(workspace, password, remote_ignore, callback)
  local ok, config = pcall(self.workspace_options, self, workspace)
  if not ok then
    callback(false, config)
    return
  end
  local resolved = self:resolve_ssh(config.host, config.ssh_command)
  config.ssh_config_file = config.ssh_config_file or resolved.config_file
  if config.auth == "password" then
    config._password = password
  end
  util.ensure_dir(config.state_root)
  local filter_path = util.join(config.state_root, "estimate-filter")
  util.write_file(filter_path, Ignore.compile(config.default_ignore, remote_ignore, {}))
  local transport = Transport.new(config, require("remote-mirror.async").runner)
  require("remote-mirror.async").run(function()
    return transport:estimate(filter_path, remote_ignore)
  end, callback)
end

function M:write_remote_ignore_async(workspace, password, contents, callback)
  local ok, config = pcall(self.workspace_options, self, workspace)
  if not ok then
    callback(false, config)
    return
  end
  local resolved = self:resolve_ssh(config.host, config.ssh_command)
  config.ssh_config_file = config.ssh_config_file or resolved.config_file
  if config.auth == "password" then
    config._password = password
  end
  local transport = Transport.new(config, require("remote-mirror.async").runner)
  require("remote-mirror.async").run(function()
    transport:write_remote_ignore(contents)
    return true
  end, callback)
end

function M:require_current()
  assert(self.current, "remote-mirror: use :RemoteMirrorConnect first")
  return self.current
end

function M:stop()
  self:cancel_review()
  if self.current then
    self.current:detach()
  end
end

return M
