local util = require("remote-mirror.util")

local M = {}
M.__index = M

function M.new(path)
  return setmetatable({
    path = path,
    workspaces = {},
  }, M)
end

function M:load()
  local contents = util.read_file(self.path)
  if not contents or contents == "" then
    return self
  end
  local ok, decoded = pcall(vim.json.decode, contents)
  assert(ok and type(decoded) == "table", "remote-mirror: workspace registry is invalid JSON")
  self.workspaces = decoded.workspaces or {}
  return self
end

function M:save()
  util.write_file(self.path, vim.json.encode({
    version = 1,
    workspaces = self.workspaces,
  }))
end

function M:add(workspace)
  self.workspaces[workspace.name] = {
    name = workspace.name,
    host = workspace.host,
    user = workspace.user,
    port = workspace.port,
    auth = workspace.auth or "ssh",
    transfer = workspace.transfer or "rsync",
    ssh_config_file = workspace.ssh_config_file,
    ssh_command = workspace.ssh_command,
    ssh_args = workspace.ssh_args,
    rsync_command = workspace.rsync_command,
    rsync_args = workspace.rsync_args,
    scp_command = workspace.scp_command,
    scp_args = workspace.scp_args,
    remote_find_command = workspace.remote_find_command,
    remote_stat_command = workspace.remote_stat_command,
    remote_sha256sum_command = workspace.remote_sha256sum_command,
    remote_du_command = workspace.remote_du_command,
    remote_root = workspace.remote_root,
    mirror_root = workspace.mirror_root,
    source_root = workspace.source_root,
    state_root = workspace.state_root,
    tree_root = workspace.tree_root,
    default_ignore = workspace.default_ignore,
  }
  self:save()
end

function M:remove(name)
  self.workspaces[name] = nil
  self:save()
end

function M:list()
  local workspaces = {}
  for _, workspace in pairs(self.workspaces) do
    table.insert(workspaces, workspace)
  end
  table.sort(workspaces, function(left, right)
    return left.name < right.name
  end)
  return workspaces
end

return M
