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
  self.data = decoded
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
