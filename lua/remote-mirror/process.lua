local M = {}

local function system_options(options)
  options = options or {}
  return {
    cwd = options.cwd,
    env = options.env,
    text = true,
    stdin = options.stdin,
    timeout = options.timeout,
  }
end

function M.check(command, options, result)
  options = options or {}
  if result.code ~= 0 and not options.allow_failure then
    local detail = result.stderr ~= "" and result.stderr or result.stdout
    error(("%s failed (%d): %s"):format(command[1], result.code, vim.trim(detail or "")))
  end

  return result
end

function M.run(command, options)
  local result = vim.system(command, system_options(options)):wait()
  return M.check(command, options, result)
end

function M.start(command, options, callback)
  local ok, system_or_error = pcall(vim.system, command, system_options(options), vim.schedule_wrap(function(result)
    local checked, value = pcall(M.check, command, options, result)
    callback(checked, value)
  end))
  if not ok then
    vim.schedule(function()
      callback(false, system_or_error)
    end)
    return nil
  end
  return system_or_error
end

return M
