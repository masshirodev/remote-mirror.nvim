local util = require("remote-mirror.util")

local M = {}
M.__index = M

function M.new(config)
  return setmetatable({
    path = util.join(config.state_root, "state.json"),
    data = {
      version = 1,
      project = {
        host = config.host,
        user = config.user,
        port = config.port,
        auth = config.auth or "ssh",
        transfer = config.transfer or "rsync",
        ssh_config_file = config.ssh_config_file,
        remote_root = config.remote_root,
      },
      files = {},
      conflicts = {},
    },
  }, M)
end

function M:load()
  local content = util.read_file(self.path)
  if not content or content == "" then
    return self
  end

  local ok, decoded = pcall(vim.json.decode, content)
  assert(ok and type(decoded) == "table", "remote-mirror: state file is invalid JSON")
  assert(decoded.version == 1, "remote-mirror: unsupported state version")
  decoded.files = decoded.files or {}
  decoded.conflicts = decoded.conflicts or {}
  local stored = type(decoded.project) == "table" and decoded.project or {}
  -- A reused mirror must describe the workspace selected for this connection,
  -- not the endpoint that happened to create its first state file.
  decoded.project = self.data.project
  self.data = decoded

  -- Recorded hashes and file entries only describe the endpoint that produced
  -- them, so a mirror pointed at a different one is reported rather than
  -- silently adopted. Mirrors written before this was recorded are adopted.
  if stored.host and stored.remote_root then
    local same = stored.host == self.data.project.host
      and stored.remote_root == self.data.project.remote_root
    if not same then
      self.foreign = { host = stored.host, remote_root = stored.remote_root }
    end
  end
  return self
end

function M:save()
  util.write_file(self.path, vim.json.encode(self.data))
end

function M:add_conflict(path, kind, local_hash, remote_hash, base_hash)
  self.data.conflicts[path] = {
    kind = kind,
    local_hash = local_hash or vim.NIL,
    remote_hash = remote_hash or vim.NIL,
    base_hash = base_hash or vim.NIL,
    detected_at = os.time(),
  }
end

function M:clear_conflict(path)
  self.data.conflicts[path] = nil
end

return M
