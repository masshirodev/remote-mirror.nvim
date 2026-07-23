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
    ssh_config_file = workspace.ssh_config_file,
    remote_root = workspace.remote_root,
    mirror_root = workspace.mirror_root,
    source_root = workspace.source_root,
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
