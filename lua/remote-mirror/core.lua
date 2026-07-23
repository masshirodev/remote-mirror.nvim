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
    operation_queue = {},
    operation_active = false,
  }, M)
end

function M:enqueue(operation, callback)
  table.insert(self.operation_queue, {
    operation = operation,
    callback = callback,
  })
  self:_drain_operations()
end

function M:_drain_operations()
  if self.operation_active or #self.operation_queue == 0 then
    return
  end
  self.operation_active = true
  local item = table.remove(self.operation_queue, 1)
  require("remote-mirror.async").run(item.operation, function(ok, result)
    self.operation_active = false
    if item.callback then
      item.callback(ok, result)
    end
    self:_drain_operations()
  end)
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
      if not entry.remote_signature then
        entry.remote_signature = metadata.signature
      end
      entry.observed_remote_signature = metadata.signature
      if entry.remote_signature ~= metadata.signature then
        changed = changed + 1
        if entry.materialized then
          local observed = self.transport:inspect(path)
          entry.observed_remote_hash = observed and observed.hash or vim.NIL
          if local_files[path]
            and local_files[path] ~= entry.local_hash
            and observed
            and entry.remote_hash ~= observed.hash
          then
            self.state:add_conflict(path, "both_modified", local_files[path], observed.hash, entry.remote_hash)
            conflicts = conflicts + 1
          end
        end
      end
    else
      local collision = local_files[path] ~= nil
      self.state.data.files[path] = {
        remote_hash = vim.NIL,
        remote_signature = collision and vim.NIL or metadata.signature,
        observed_remote_signature = metadata.signature,
        materialized = collision,
        local_hash = vim.NIL,
        size = metadata.size,
        mtime = metadata.mtime,
      }
      if collision then
        self.state:add_conflict(path, "both_created", local_files[path], metadata.signature, nil)
        conflicts = conflicts + 1
      end
      changed = changed + 1
    end
  end

  for path, entry in pairs(self.state.data.files) do
    if not remote[path] then
      entry.observed_remote_signature = vim.NIL
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
        remote_hash = local_after[path] or vim.NIL,
        remote_signature = metadata.signature,
        observed_remote_signature = metadata.signature,
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

function M:_filter_path(name)
  local filter_path = util.join(self.config.state_root, name)
  local remote_ignore = self.transport:remote_ignore()
  util.write_file(filter_path, ignore.compile(self.config.default_ignore, remote_ignore, {}))
  return filter_path
end

function M:_replace_state_from_remote(remote, local_files)
  local files = {}
  for path, metadata in pairs(remote) do
    local local_hash = local_files[path]
    files[path] = {
      remote_hash = local_hash or vim.NIL,
      remote_signature = metadata.signature,
      observed_remote_signature = metadata.signature,
      local_hash = local_hash or vim.NIL,
      materialized = local_hash ~= nil,
      size = metadata.size,
      mtime = metadata.mtime,
    }
  end
  self.state.data.files = files
  self.state.data.conflicts = {}
end

function M:force_pull()
  self:ensure_layout()
  local remote = self.transport:manifest()
  self.transport:pull(self:_filter_path("force-pull-filter"))
  local local_files = util.walk_files(self.config.source_root)
  self:_replace_state_from_remote(remote, local_files)
  self.state.data.last_pull = os.time()
  self.state:save()
  if self.watcher then
    self.watcher:resnapshot()
  end
  return { files = vim.tbl_count(remote) }
end

function M:force_push()
  self:ensure_layout()
  self.transport:push(self:_filter_path("force-push-filter"))
  local remote = self.transport:manifest()
  local local_files = util.walk_files(self.config.source_root)
  self:_replace_state_from_remote(remote, local_files)
  self.state.data.last_push = os.time()
  self.state:save()
  if self.watcher then
    self.watcher:resnapshot()
  end
  return { files = vim.tbl_count(local_files) }
end

function M:reconcile_plan()
  self:ensure_layout()
  local remote = self.transport:manifest()
  local local_files = util.walk_files(self.config.source_root)
  local changes = self.transport:changes(self:_filter_path("review-filter"))
  for _, change in ipairs(changes) do
    change.default_action = "pull"
    change.local_hash = local_files[change.path]
    if change.remote_exists then
      local inspected = self.transport:inspect(change.path)
      change.remote_hash = inspected and inspected.hash or nil
    end
  end
  changes.remote = remote
  changes.local_files = local_files
  return changes
end

function M:push_file(path, force, expected_remote_hash, check_expected)
  local absolute = util.join(self.config.source_root, path)
  local local_hash = util.hash_file(absolute)
  local entry = self.state.data.files[path]
  local remote_metadata = self.transport:inspect(path)
  local remote_hash = remote_metadata and remote_metadata.hash or nil
  local base_hash = entry and entry.remote_hash or nil
  if base_hash == vim.NIL then
    base_hash = nil
  end

  local expected_hash = check_expected and expected_remote_hash or base_hash
  if (check_expected or not force) and remote_hash ~= expected_hash then
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
    local uploaded = self.transport:inspect(path)
    self.state.data.files[path] = {
      remote_hash = uploaded and uploaded.hash or local_hash,
      remote_signature = uploaded and uploaded.signature or vim.NIL,
      observed_remote_signature = uploaded and uploaded.signature or vim.NIL,
      local_hash = local_hash,
      materialized = true,
      size = uploaded and uploaded.size or vim.NIL,
      mtime = uploaded and uploaded.mtime or os.time(),
    }
  else
    self.state.data.files[path] = nil
  end
  self.state:clear_conflict(path)
  self.state.data.last_push = os.time()
  self.state:save()
  return true
end

function M:apply_reconcile(plan, actions)
  local by_path = {}
  for _, change in ipairs(plan) do
    by_path[change.path] = change
  end

  local files = {}
  for path, metadata in pairs(plan.remote or {}) do
    local local_hash = plan.local_files and plan.local_files[path] or nil
    local change = by_path[path]
    local previous = self.state.data.files[path]
    files[path] = {
      remote_hash = change and (change.remote_hash or vim.NIL)
        or (previous and previous.remote_hash)
        or local_hash
        or vim.NIL,
      remote_signature = metadata.signature,
      observed_remote_signature = metadata.signature,
      local_hash = local_hash or vim.NIL,
      materialized = local_hash ~= nil,
      size = metadata.size,
      mtime = metadata.mtime,
    }
  end
  for path, change in pairs(by_path) do
    if change.local_exists and not change.remote_exists then
      files[path] = {
        remote_hash = vim.NIL,
        remote_signature = vim.NIL,
        observed_remote_signature = vim.NIL,
        local_hash = change.local_hash or vim.NIL,
        materialized = true,
        size = vim.NIL,
        mtime = vim.NIL,
      }
    end
  end
  self.state.data.files = files
  self.state.data.conflicts = {}

  local applied, skipped, conflicts = 0, 0, 0
  for path, action in pairs(actions) do
    local change = assert(by_path[path], "remote-mirror: reviewed path is no longer available")
    assert(action == "pull" or action == "push" or action == "skip", "remote-mirror: invalid review action")

    if action == "skip" then
      skipped = skipped + 1
      self.state:add_conflict(
        path,
        "reconnect_skipped",
        change.local_hash,
        change.remote_hash,
        self.state.data.files[path] and self.state.data.files[path].remote_hash or nil
      )
    elseif action == "pull" then
      if change.remote_exists then
        self.transport:download(path)
        local inspected = self.transport:inspect(path)
        local local_hash = util.hash_file(util.join(self.config.source_root, path))
        self.state.data.files[path] = {
          remote_hash = inspected and inspected.hash or local_hash,
          remote_signature = inspected and inspected.signature or vim.NIL,
          observed_remote_signature = inspected and inspected.signature or vim.NIL,
          local_hash = local_hash or vim.NIL,
          materialized = local_hash ~= nil,
          size = inspected and inspected.size or vim.NIL,
          mtime = inspected and inspected.mtime or os.time(),
        }
      else
        local absolute = util.join(self.config.source_root, path)
        local removed, err = os.remove(absolute)
        assert(
          removed or not util.is_file(absolute),
          ("remote-mirror: could not delete local file %s: %s"):format(path, err or "unknown error")
        )
        self.state.data.files[path] = nil
      end
      self.state:clear_conflict(path)
      applied = applied + 1
    else
      local ok = self:push_file(path, true, change.remote_hash, true)
      if ok then
        applied = applied + 1
      else
        conflicts = conflicts + 1
      end
    end
  end

  self.state:save()
  return { applied = applied, skipped = skipped, conflicts = conflicts }
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
        remote_hash = hash,
        remote_signature = remote[path].signature,
        observed_remote_signature = remote[path].signature,
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
    entry.remote_hash = entry.local_hash
    entry.remote_signature = entry.observed_remote_signature or entry.remote_signature
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
    self:enqueue(function()
      return self:push_file(path, false)
    end, function(ok, result)
      self.pending[path] = nil
      if not ok then
        util.notify(result, vim.log.levels.ERROR)
      elseif not result then
        util.notify(("%s was not uploaded because the remote changed"):format(path), vim.log.levels.WARN)
      end

      local local_hash = util.hash_file(util.join(self.config.source_root, path))
      local entry = self.state.data.files[path]
      if (local_hash and (not entry or local_hash ~= entry.local_hash))
        or (not local_hash and entry and entry.materialized)
      then
        self:schedule_upload(path)
      end
    end)
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
