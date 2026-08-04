local util = require("remote-mirror.util")

local M = {}
M.__index = M

function M.new(core)
  return setmetatable({
    core = core,
    handles = {},
    snapshot = {},
    scan_pending = false,
    stopped = true,
  }, M)
end

function M:_close_handles()
  for _, handle in ipairs(self.handles) do
    if not handle:is_closing() then
      handle:stop()
      handle:close()
    end
  end
  self.handles = {}
end

-- The watcher rescans constantly, so the same unreadable path would otherwise
-- produce one warning per filesystem event. Only a change in what is wrong is
-- worth reporting again, and a resolved problem is forgotten so its return is.
function M:_report(key, message, level)
  self.reported = self.reported or {}
  if self.reported[key] == message then
    return
  end
  self.reported[key] = message
  if message then
    util.notify(message, level)
  end
end

function M:_watch_directories()
  self:_close_handles()
  local unwatched = {}
  for _, directory in ipairs(util.walk_directories(self.core.config.source_root)) do
    local handle = vim.uv.new_fs_event()
    if handle then
      local ok, start_error = handle:start(directory, {}, vim.schedule_wrap(function(err)
        if err then
          util.notify(("watch failed for %s: %s"):format(directory, err), vim.log.levels.WARN)
          return
        end
        self:schedule_scan()
      end))
      if ok then
        table.insert(self.handles, handle)
      else
        -- A directory that cannot be watched still receives external edits;
        -- they simply stop reaching the upload path, which is worth saying.
        local relative = util.relative_path(self.core.config.source_root, directory)
        table.insert(unwatched, ("%s (%s)"):format(
          (relative and relative ~= "") and relative or ".",
          start_error or "could not be watched"
        ))
        handle:close()
      end
    end
  end

  self:_report(
    "unwatched",
    #unwatched > 0 and ("%d directory(ies) are not being watched for external changes: %s"):format(
      #unwatched,
      table.concat(unwatched, ", ")
    ) or nil,
    vim.log.levels.WARN
  )
end

function M:scan()
  if self.stopped then
    return
  end
  local current, unreadable = util.walk_files(self.core.config.source_root)
  self:_report(
    "unreadable",
    #unreadable > 0 and util.unreadable_message(unreadable) or nil,
    vim.log.levels.WARN
  )
  local changed = {}

  for path, hash in pairs(current) do
    if self.snapshot[path] ~= hash then
      changed[path] = true
    end
  end
  for path in pairs(self.snapshot) do
    if not current[path] then
      changed[path] = true
    end
  end

  self.snapshot = current
  self:_watch_directories()
  for path in pairs(changed) do
    self.core:schedule_upload(path)
  end
end

function M:schedule_scan()
  if self.stopped or self.scan_pending then
    return
  end
  self.scan_pending = true
  vim.defer_fn(function()
    self.scan_pending = false
    self:scan()
  end, self.core.config.watch_debounce_ms)
end

function M:resnapshot()
  self.snapshot = util.walk_files(self.core.config.source_root)
  if not self.stopped then
    self:_watch_directories()
  end
end

function M:start()
  self.stopped = false
  self:resnapshot()
end

function M:stop()
  self.stopped = true
  self.scan_pending = false
  self:_close_handles()
end

return M
