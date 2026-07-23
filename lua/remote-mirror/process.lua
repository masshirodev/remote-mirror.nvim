local M = {}

function M.run(command, options)
  options = options or {}
  local result = vim.system(command, {
    cwd = options.cwd,
    text = true,
    stdin = options.stdin,
  }):wait()

  if result.code ~= 0 and not options.allow_failure then
    local detail = result.stderr ~= "" and result.stderr or result.stdout
    error(("%s failed (%d): %s"):format(command[1], result.code, vim.trim(detail or "")))
  end

  return result
end

return M
