local M = {}

-- `on_stdout` runs in a libuv callback, where the Neovim API is unavailable, so
-- it may only record what it reads. The output is still collected here, because
-- installing a reader replaces the accumulation `vim.system` would do and
-- callers parse the result of the same commands they watch.
local function system_options(options, collected)
  options = options or {}
  local system = {
    cwd = options.cwd,
    env = options.env,
    text = true,
    stdin = options.stdin,
    timeout = options.timeout,
  }
  if options.on_stdout then
    system.stdout = function(_, data)
      if data then
        table.insert(collected, data)
        options.on_stdout(data)
      end
    end
  end
  return system
end

local function restore_stdout(options, collected, result)
  if options and options.on_stdout then
    result.stdout = table.concat(collected)
  end
  return result
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
  local collected = {}
  local result = vim.system(command, system_options(options, collected)):wait()
  return M.check(command, options, restore_stdout(options, collected, result))
end

function M.start(command, options, callback)
  local collected = {}
  local ok, system_or_error = pcall(vim.system, command, system_options(options, collected), vim.schedule_wrap(function(result)
    local checked, value = pcall(M.check, command, options, restore_stdout(options, collected, result))
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
