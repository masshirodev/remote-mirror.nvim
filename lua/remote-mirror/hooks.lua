local process = require("remote-mirror.process")
local util = require("remote-mirror.util")

local M = {}

local hook_names = {
  onConnected = true,
  onDisconnected = true,
  onRemoteCommand = true,
}

local function hook_path(config, name)
  assert(hook_names[name], "remote-mirror: unknown hook " .. name)
  return util.join(config.mirror_root, name)
end

function M.path(config, name)
  return hook_path(config, name)
end

function M.script(config, name)
  local path = hook_path(config, name)
  if not util.is_file(path) then
    return nil
  end
  local contents, err = util.read_file(path)
  assert(contents, ("remote-mirror: could not read %s: %s"):format(path, err or "unknown error"))
  return contents
end

function M.has(config, name)
  return M.script(config, name) ~= nil
end

function M.environment(config)
  return {
    REMOTE_MIRROR_WORKSPACE = config.name,
    REMOTE_MIRROR_HOST = config.host,
    REMOTE_MIRROR_USER = config.user or "",
    REMOTE_MIRROR_REMOTE_ROOT = config.remote_root,
    REMOTE_MIRROR_MIRROR_ROOT = config.mirror_root,
    REMOTE_MIRROR_SOURCE_ROOT = config.source_root,
  }
end

function M.run(config, name)
  local path = hook_path(config, name)
  if not util.is_file(path) then
    return nil
  end
  return process.run({ "sh", path }, {
    cwd = config.mirror_root,
    env = M.environment(config),
  })
end

function M.run_async(config, name, callback)
  local path = hook_path(config, name)
  if not util.is_file(path) then
    callback(true, nil)
    return
  end
  process.start({ "sh", path }, {
    cwd = config.mirror_root,
    env = M.environment(config),
  }, callback)
end

function M.remote_script(config)
  return M.script(config, "onRemoteCommand")
end

return M
