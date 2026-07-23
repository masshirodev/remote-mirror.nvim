local ignore = require("remote-mirror.ignore")
local State = require("remote-mirror.state")
local Transport = require("remote-mirror.transport")
local util = require("remote-mirror.util")

local M = {}
M.__index = M

function M.new(config, dependencies)
  dependencies = dependencies or {}
  local state = dependencies.state or State.new(config):load()
  return setmetatable({
    config = config,
    state = state,
    transport = dependencies.transport or Transport.new(config),
    pending = {},
  }, M)
end

function M:ensure_layout()
  util.ensure_dir(self.config.source_root)
  util.ensure_dir(self.config.state_root)
  util.ensure_dir(self.config.tree_root)
end

function M:refresh()
  self:ensure_layout()
  local remote = self.transport:manifest()
  local local_files = util.walk_files(self.config.source_root)
  local changed, conflicts = 0, 0

  for path, metadata in pairs(remote) do
    local entry = self.state.data.files[path]
    if entry then
      entry.observed_remote_hash = metadata.hash
      if entry.remote_hash ~= metadata.hash then
        changed = changed + 1
        if local_files[path] and local_files[path] ~= entry.local_hash then
          self.state:add_conflict(path, "both_modified", local_files[path], metadata.hash, entry.remote_hash)
          conflicts = conflicts + 1
        end
      end
    else
      local collision = local_files[path] ~= nil
      self.state.data.files[path] = {
        remote_hash = collision and vim.NIL or metadata.hash,
        observed_remote_hash = metadata.hash,
        materialized = collision,
        local_hash = vim.NIL,
        size = metadata.size,
        mtime = metadata.mtime,
      }
      if collision then
        self.state:add_conflict(path, "both_created", local_files[path], metadata.hash, nil)
        conflicts = conflicts + 1
      end
      changed = changed + 1
    end
  end

  for path, entry in pairs(self.state.data.files) do
    if not remote[path] then
      entry.observed_remote_hash = vim.NIL
      if entry.remote_hash ~= vim.NIL then
        changed = changed + 1
        if local_files[path] and local_files[path] ~= entry.local_hash then
          self.state:add_conflict(path, "remote_deleted", local_files[path], nil, entry.remote_hash)
          conflicts = conflicts + 1
        end
      end
    end
  end

  self.state.data.last_refresh = os.time()
  self.state:save()
  return { remote = remote, local_files = local_files, changed = changed, conflicts = conflicts }
end

function M:pull()
  self:ensure_layout()
  local snapshot = self:refresh()
  local protected = {}

  for path, hash in pairs(snapshot.local_files) do
    local entry = self.state.data.files[path]
    if not entry or hash ~= entry.local_hash then
      table.insert(protected, path)
    end
  end

  local filter_path = util.join(self.config.state_root, "rsync-filter")
  local remote_ignore = self.transport:remote_ignore()
  util.write_file(filter_path, ignore.compile(self.config.default_ignore, remote_ignore, protected))
  self.transport:pull(filter_path)

  local local_after = util.walk_files(self.config.source_root)
  local protected_set = {}
  for _, path in ipairs(protected) do
    protected_set[path] = true
  end

  for path, metadata in pairs(snapshot.remote) do
    if not protected_set[path] then
      self.state.data.files[path] = {
        remote_hash = metadata.hash,
        observed_remote_hash = metadata.hash,
        local_hash = local_after[path] or vim.NIL,
        materialized = local_after[path] ~= nil,
        size = metadata.size,
        mtime = metadata.mtime,
      }
      self.state:clear_conflict(path)
    end
  end

  for path, entry in pairs(self.state.data.files) do
    if not snapshot.remote[path] and not protected_set[path] then
      self.state.data.files[path] = nil
      self.state:clear_conflict(path)
    elseif entry and local_after[path] == nil then
      entry.materialized = false
    end
  end

  self.state.data.last_pull = os.time()
  self.state:save()
  if self.watcher then
    self.watcher:resnapshot()
  end
  return { protected = protected, files = vim.tbl_count(snapshot.remote) }
end

function M:push_file(path, force)
  local absolute = util.join(self.config.source_root, path)
  local local_hash = util.hash_file(absolute)
  local entry = self.state.data.files[path]
  local remote = self.transport:manifest()
  local remote_metadata = remote[path]
  local remote_hash = remote_metadata and remote_metadata.hash or nil
  local base_hash = entry and entry.remote_hash or nil

  if not force and remote_hash ~= base_hash then
    self.state:add_conflict(path, "remote_modified", local_hash, remote_hash, base_hash)
    self.state:save()
    return false, "remote file changed"
  end

  if local_hash then
    self.transport:upload(path)
  else
    self.transport:delete(path)
  end

  if local_hash then
    self.state.data.files[path] = {
      remote_hash = local_hash,
      observed_remote_hash = local_hash,
      local_hash = local_hash,
      materialized = true,
      size = remote_metadata and remote_metadata.size or vim.NIL,
      mtime = os.time(),
    }
  else
    self.state.data.files[path] = nil
  end
  self.state:clear_conflict(path)
  self.state.data.last_push = os.time()
  self.state:save()
  return true
end

function M:push()
  self:ensure_layout()
  local local_files = util.walk_files(self.config.source_root)
  local paths = {}
  for path, hash in pairs(local_files) do
    local entry = self.state.data.files[path]
    if not entry or hash ~= entry.local_hash then
      paths[path] = true
    end
  end
  for path, entry in pairs(self.state.data.files) do
    if entry.materialized and not local_files[path] then
      paths[path] = true
    end
  end

  local pushed, conflicts = 0, 0
  for path in pairs(paths) do
    local ok = self:push_file(path, false)
    if ok then
      pushed = pushed + 1
    else
      conflicts = conflicts + 1
    end
  end
  return { pushed = pushed, conflicts = conflicts }
end

function M:resolve(path, strategy)
  assert(self.state.data.conflicts[path], "remote-mirror: no conflict recorded for " .. path)
  if strategy == "push" then
    self:push_file(path, true)
  elseif strategy == "pull" then
    local remote = self.transport:manifest()
    if remote[path] then
      self.transport:download(path)
      local hash = util.hash_file(util.join(self.config.source_root, path))
      self.state.data.files[path] = {
        remote_hash = remote[path].hash,
        observed_remote_hash = remote[path].hash,
        local_hash = hash,
        materialized = true,
        size = remote[path].size,
        mtime = remote[path].mtime,
      }
    else
      os.remove(util.join(self.config.source_root, path))
      self.state.data.files[path] = nil
    end
    self.state:clear_conflict(path)
    self.state:save()
  else
    error("remote-mirror: strategy must be pull or push")
  end
end

function M:materialize(path)
  local entry = self.state.data.files[path]
  assert(entry, "remote-mirror: unknown remote file " .. path)
  if not entry.materialized then
    self.transport:download(path)
    entry.local_hash = util.hash_file(util.join(self.config.source_root, path))
    entry.remote_hash = entry.observed_remote_hash or entry.remote_hash
    entry.materialized = true
    self.state:save()
    if self.watcher then
      self.watcher:resnapshot()
    end
  end
  return util.join(self.config.source_root, path)
end

function M:schedule_upload(path)
  local local_hash = util.hash_file(util.join(self.config.source_root, path))
  local entry = self.state.data.files[path]
  if (local_hash and entry and local_hash == entry.local_hash)
    or (not local_hash and (not entry or not entry.materialized))
  then
    return
  end
  if self.pending[path] then
    return
  end
  self.pending[path] = true
  vim.defer_fn(function()
    self.pending[path] = nil
    local ok, result, reason = pcall(self.push_file, self, path, false)
    if not ok then
      util.notify(result, vim.log.levels.ERROR)
    elseif not result then
      util.notify(("%s was not uploaded: %s"):format(path, reason), vim.log.levels.WARN)
    end
  end, self.config.debounce_ms)
end

function M:start_watcher()
  if not self.config.watch then
    return
  end
  if self.watcher then
    self.watcher:stop()
  end
  self.watcher = require("remote-mirror.watcher").new(self)
  self.watcher:start()
end

function M:stop_watcher()
  if self.watcher then
    self.watcher:stop()
    self.watcher = nil
  end
end

return M
