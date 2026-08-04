-- Transfers happen over SSH, and the first synchronization of a large remote
-- workspace can run for minutes without Neovim showing anything at all, which
-- is indistinguishable from the plugin having failed. Every long operation
-- registers itself here, and this module is the single place that reports what
-- is running: a small window in the corner, and a statusline component for
-- users who prefer their own.

local M = {}

local defaults = {
  window = true,
  spinner = { "-", "\\", "|", "/" },
  interval_ms = 120,
  delay_ms = 250,
}

M.options = vim.deepcopy(defaults)

local jobs = {}
local last_id = 0
local frame = 1
local timer
local window
local buffer

local Handle = {}
Handle.__index = Handle

local function headless()
  return #vim.api.nvim_list_uis() == 0
end

local function line()
  local job = jobs[#jobs]
  if not job then
    return nil
  end
  local text = job.label
  if job.detail and job.detail ~= "" then
    text = ("%s  %s"):format(text, job.detail)
  end
  if #jobs > 1 then
    text = ("%s  (+%d)"):format(text, #jobs - 1)
  end
  return ("%s  %s"):format(M.options.spinner[frame] or "-", text)
end

local function close_window()
  if window and vim.api.nvim_win_is_valid(window) then
    pcall(vim.api.nvim_win_close, window, true)
  end
  window = nil
end

local function draw(text)
  if not buffer or not vim.api.nvim_buf_is_valid(buffer) then
    buffer = vim.api.nvim_create_buf(false, true)
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
  end

  local available = math.max(20, vim.o.columns - 4)
  local width = math.min(math.max(vim.fn.strdisplaywidth(text), 20), available)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { text })

  local configuration = {
    relative = "editor",
    anchor = "NE",
    row = 1,
    col = math.max(vim.o.columns - 1, 1),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 190,
  }
  if window and vim.api.nvim_win_is_valid(window) then
    pcall(vim.api.nvim_win_set_config, window, configuration)
    return
  end

  configuration.noautocmd = true
  local ok, handle = pcall(vim.api.nvim_open_win, buffer, false, configuration)
  if not ok then
    return
  end
  window = handle
  vim.wo[window].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  vim.wo[window].wrap = false
end

-- A focus check that answers in 40 milliseconds would otherwise open and close
-- a window between two keystrokes. The statusline component has no such
-- problem and reports from the first tick.
local function window_due()
  local job = jobs[#jobs]
  return job ~= nil and (vim.uv.now() - job.started_at) >= M.options.delay_ms
end

function M.render()
  if headless() then
    return
  end
  local text = line()
  if text and M.options.window and window_due() then
    draw(text)
  else
    close_window()
  end
  pcall(vim.cmd, "redrawstatus")
end

local function tick()
  frame = frame % math.max(#M.options.spinner, 1) + 1
  M.render()
end

local function start_timer()
  if timer then
    return
  end
  timer = vim.uv.new_timer()
  if not timer then
    return
  end
  timer:start(M.options.interval_ms, M.options.interval_ms, vim.schedule_wrap(tick))
end

local function stop_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  assert(type(M.options.spinner) == "table" and #M.options.spinner > 0, "remote-mirror: progress.spinner must be a non-empty table")
  assert(M.options.interval_ms > 0, "remote-mirror: progress.interval_ms must be positive")
  assert(M.options.delay_ms >= 0, "remote-mirror: progress.delay_ms must be non-negative")

  local group = vim.api.nvim_create_augroup("RemoteMirrorProgress", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      M.render()
    end,
    desc = "Reposition the remote-mirror progress window",
  })
end

-- `label` is what the user reads while the operation runs, so it names the
-- workspace rather than the function performing the work.
function M.start(label)
  last_id = last_id + 1
  local job = setmetatable({ id = last_id, label = label, started_at = vim.uv.now() }, Handle)
  table.insert(jobs, job)
  start_timer()
  M.render()
  return job
end

function Handle:step(label, detail)
  self.label = label
  self.detail = detail
  M.render()
end

-- Called from libuv read callbacks, where the Neovim API is off limits, so the
-- text is only recorded here; the spinner timer is what draws it.
function Handle:update(detail)
  self.detail = detail
end

function Handle:finish()
  for index, job in ipairs(jobs) do
    if job.id == self.id then
      table.remove(jobs, index)
      break
    end
  end
  if #jobs == 0 then
    stop_timer()
    frame = 1
  end
  M.render()
end

-- Transports report bytes and file counts without holding a handle: the
-- operation that started the job is several calls up the stack.
function M.detail(detail)
  local job = jobs[#jobs]
  if job then
    job.detail = detail
  end
end

function M.active()
  return #jobs > 0
end

function M.status()
  return line() or ""
end

-- Only used by the test suite and by :RemoteMirrorDisconnect!, where a job can
-- outlive the workspace it was reporting on.
function M.reset()
  jobs = {}
  stop_timer()
  frame = 1
  M.render()
end

return M
