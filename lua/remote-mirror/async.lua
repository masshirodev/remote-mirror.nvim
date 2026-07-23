local process = require("remote-mirror.process")

local M = {}

function M.runner(command, options)
  if not coroutine.running() then
    return process.run(command, options)
  end

  local response = coroutine.yield({
    command = command,
    options = options,
  })
  if not response.ok then
    error(response.value)
  end
  return response.value
end

function M.run(operation, callback)
  local thread = coroutine.create(operation)

  local function advance(response)
    local ok, request_or_result = coroutine.resume(thread, response)
    if not ok then
      callback(false, request_or_result)
      return
    end
    if coroutine.status(thread) == "dead" then
      callback(true, request_or_result)
      return
    end

    local request = request_or_result
    assert(
      type(request) == "table" and type(request.command) == "table",
      "remote-mirror: async operation yielded an invalid process request"
    )
    process.start(request.command, request.options, function(process_ok, value)
      advance({ ok = process_ok, value = value })
    end)
  end

  advance(nil)
end

return M
