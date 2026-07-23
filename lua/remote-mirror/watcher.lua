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

function M:_watch_directories()
  self:_close_handles()
  for _, directory in ipairs(util.walk_directories(self.core.config.source_root)) do
    local handle = vim.uv.new_fs_event()
    if handle then
      local ok = handle:start(directory, {}, vim.schedule_wrap(function(err)
        if err then
          util.notify(("watch failed for %s: %s"):format(directory, err), vim.log.levels.WARN)
          return
        end
        self:schedule_scan()
      end))
      if ok then
        table.insert(self.handles, handle)
      else
        handle:close()
      end
    end
  end
end

function M:scan()
  if self.stopped then
    return
  end
  local current = util.walk_files(self.core.config.source_root)
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
