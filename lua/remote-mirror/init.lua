local Manager = require("remote-mirror.manager")

local M = {
  _manager = nil,
}

function M.setup(options)
  options = options or {}
  if M._manager then
    M._manager:stop()
  end
  require("remote-mirror.notify").setup(options.notifications)
  require("remote-mirror.progress").setup(options.progress)
  local manager = Manager.new(options)
  require("remote-mirror.commands").register(manager)
  M._manager = manager
  return manager
end

-- Statusline component: empty while nothing is running, so it takes no room in
-- an idle session.
function M.status()
  return require("remote-mirror.progress").status()
end

local function manager()
  if not M._manager then
    M.setup()
  end
  return M._manager
end

function M.connect(name)
  return manager():connect(name)
end

function M.disconnect(force)
  return manager():disconnect(force)
end

function M.reset(name)
  return manager():reset_mirror(name)
end

function M.pull()
  return manager():require_current():pull()
end

function M.push()
  return manager():require_current():push()
end

function M.refresh()
  return manager():require_current():refresh()
end

function M.poll(on_complete)
  return manager():require_current():schedule_poll(on_complete)
end

return M
