local process = require("remote-mirror.process")

local M = {}

function M.resolve(ssh_command, host, runner)
  runner = runner or process.run
  local command = { ssh_command, "-G", host }
  local result = runner(command, { allow_failure = true })
  local config_file
  if result.code ~= 0 and (result.stderr or ""):find("Bad owner or permissions", 1, true) then
    local user_config = vim.fn.expand("~/.ssh/config")
    config_file = vim.uv.fs_stat(user_config) and user_config or "/dev/null"
    command = { ssh_command, "-F", config_file, "-G", host }
    result = runner(command, { allow_failure = true })
  end
  if result.code ~= 0 then
    return {
      host = host,
      port = 22,
      source = "default",
      error = vim.trim(result.stderr or ""),
    }
  end

  local resolved = {
    host = host,
    identity_files = {},
    source = "ssh-config",
    config_file = config_file,
  }
  for line in result.stdout:gmatch("[^\r\n]+") do
    local key, value = line:match("^(%S+)%s+(.+)$")
    if key == "hostname" and not resolved.hostname then
      resolved.hostname = value
    elseif key == "user" and not resolved.user then
      resolved.user = value
    elseif key == "port" and not resolved.port then
      resolved.port = tonumber(value)
    elseif key == "identityfile" then
      table.insert(resolved.identity_files, value)
    end
  end
  resolved.port = resolved.port or 22
  return resolved
end

return M
