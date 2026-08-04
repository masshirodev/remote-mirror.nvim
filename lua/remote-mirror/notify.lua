-- Failures reach the user as raw ssh or rsync output: accurate, but the line
-- that says what actually went wrong is buried in protocol noise, and a single
-- `vim.notify` call truncates it against the command line. Messages are
-- rendered in a floating window that keeps the headline and the original text
-- apart, and every message is kept for :RemoteMirrorMessages.

local M = {}

local defaults = {
  style = "popup",
  timeout = 6000,
  width = 0.5,
  history_limit = 200,
}

M.options = vim.deepcopy(defaults)
M.history = {}

local popups = {}

local level_styles = {
  [vim.log.levels.ERROR] = { name = "error", highlight = "DiagnosticError" },
  [vim.log.levels.WARN] = { name = "warn", highlight = "DiagnosticWarn" },
  [vim.log.levels.INFO] = { name = "info", highlight = "DiagnosticInfo" },
  [vim.log.levels.DEBUG] = { name = "debug", highlight = "DiagnosticHint" },
  [vim.log.levels.TRACE] = { name = "trace", highlight = "DiagnosticHint" },
}

-- The first rule whose pattern appears in the message becomes the headline.
-- Ordering matters: the specific SSH refusals are recognized before the generic
-- permission failure they also contain.
local explanations = {
  -- A rejected password reports both itself and the identities that were tried
  -- first, so the password has to be recognized ahead of them.
  { "permission denied, please try again", "the SSH password was rejected" },
  { "permission denied %(publickey", "the host rejected every SSH identity offered" },
  { "host key verification failed", "the host key is not trusted; connect once with ssh to accept it" },
  { "could not resolve hostname", "the host name could not be resolved" },
  { "connection refused", "nothing accepted an SSH connection on that port" },
  { "connection timed out", "the host did not answer before the connect timeout" },
  { "operation timed out", "the host did not answer before the connect timeout" },
  { "connection closed by remote host", "the host closed the connection" },
  { "kex_exchange_identification", "the host closed the connection before authenticating" },
  { "too many authentication failures", "the host rejected too many SSH identities in a row" },
  { "sudo: a password is required", "remote sudo needs a password" },
  { "is not allowed to execute", "remote sudo refuses to run this command" },
  { "command not found", "a command the plugin relies on is missing on the remote host" },
  { "error in rsync protocol data stream", "rsync could not talk to the remote host" },
  { "failed: permission denied", "a file could not be written; check the permissions on both sides" },
  { "permission denied", "the operation was refused for lack of permission" },
  { "no space left on device", "the destination filesystem is full" },
  { "rsync error", "rsync reported a transfer error" },
}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
  assert(
    M.options.style == "popup" or M.options.style == "vim.notify",
    "remote-mirror: notifications.style must be popup or vim.notify"
  )
  assert(M.options.timeout > 0, "remote-mirror: notifications.timeout must be positive")
end

-- Splits a message into the one line worth reading first and the original text
-- underneath it. A message the plugin wrote itself has no detail to separate.
function M.describe(message)
  local text = vim.trim(tostring(message))
  local lowered = text:lower()
  for _, rule in ipairs(explanations) do
    if lowered:find(rule[1]) then
      return { summary = rule[2], detail = text }
    end
  end

  local first = text:match("^[^\r\n]*") or text
  local rest = vim.trim(text:sub(#first + 1))
  return { summary = first ~= "" and first or text, detail = rest ~= "" and rest or nil }
end

local function wrap(text, width)
  local lines = {}
  local indent = text:match("^(%s*)") or ""
  local current = text
  while vim.fn.strdisplaywidth(current) > width do
    local head = current:sub(1, width)
    local space = head:find("%s[^%s]*$")
    local cut = (space and space > #indent) and space - 1 or width
    table.insert(lines, current:sub(1, cut))
    local tail = vim.trim(current:sub(cut + 1))
    if tail == "" then
      return lines
    end
    current = indent .. tail
  end
  table.insert(lines, current)
  return lines
end

local function layout()
  local bottom = vim.o.lines - vim.o.cmdheight - 1
  for index = #popups, 1, -1 do
    local popup = popups[index]
    if vim.api.nvim_win_is_valid(popup.window) then
      pcall(vim.api.nvim_win_set_config, popup.window, {
        relative = "editor",
        anchor = "SE",
        row = bottom,
        col = math.max(vim.o.columns - 1, 1),
        width = popup.width,
        height = popup.height,
      })
      bottom = bottom - popup.height - 2
    end
  end
end

local function close(popup)
  for index, candidate in ipairs(popups) do
    if candidate == popup then
      table.remove(popups, index)
      break
    end
  end
  if popup.timer then
    popup.timer:stop()
  end
  if vim.api.nvim_win_is_valid(popup.window) then
    pcall(vim.api.nvim_win_close, popup.window, true)
  end
  if vim.api.nvim_buf_is_valid(popup.buffer) then
    pcall(vim.api.nvim_buf_delete, popup.buffer, { force = true })
  end
  layout()
end

local function open(entry)
  local style = level_styles[entry.level] or level_styles[vim.log.levels.INFO]
  local width = math.max(30, math.min(math.floor(vim.o.columns * M.options.width), vim.o.columns - 4))

  local lines = wrap("remote-mirror: " .. entry.summary, width)
  local summary_lines = #lines
  if entry.detail and entry.detail ~= entry.summary then
    for _, detail in ipairs(vim.split(entry.detail, "\n", { plain = true })) do
      if vim.trim(detail) ~= "" then
        vim.list_extend(lines, wrap("  " .. vim.trim(detail), width))
      end
    end
  end
  -- A wall of rsync output is worse than a truncated one; the whole message is
  -- still in :RemoteMirrorMessages.
  if #lines > 12 then
    lines = vim.list_slice(lines, 1, 11)
    table.insert(lines, "  ... :RemoteMirrorMessages shows the rest")
  end

  local longest = 0
  for _, text in ipairs(lines) do
    longest = math.max(longest, vim.fn.strdisplaywidth(text))
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false

  local ok, window = pcall(vim.api.nvim_open_win, buffer, false, {
    relative = "editor",
    anchor = "SE",
    row = vim.o.lines - vim.o.cmdheight - 1,
    col = math.max(vim.o.columns - 1, 1),
    width = math.min(longest, width),
    height = #lines,
    style = "minimal",
    border = "rounded",
    focusable = false,
    noautocmd = true,
    zindex = 200,
  })
  if not ok then
    vim.notify("remote-mirror: " .. entry.summary, entry.level)
    return
  end

  vim.wo[window].winhighlight = ("Normal:NormalFloat,FloatBorder:%s"):format(style.highlight)
  vim.wo[window].wrap = false
  for index = 0, summary_lines - 1 do
    pcall(vim.api.nvim_buf_add_highlight, buffer, -1, style.highlight, index, 0, -1)
  end

  local popup = {
    window = window,
    buffer = buffer,
    width = math.min(longest, width),
    height = #lines,
  }
  table.insert(popups, popup)
  layout()

  -- An error is the message the user most needs to finish reading, so it stays
  -- up longer than the running commentary around it.
  local timeout = entry.level >= vim.log.levels.ERROR and M.options.timeout * 2 or M.options.timeout
  popup.timer = vim.defer_fn(function()
    close(popup)
  end, timeout)
end

function M.dismiss()
  for index = #popups, 1, -1 do
    close(popups[index])
  end
end

function M.show(message, level)
  level = level or vim.log.levels.INFO
  local described = M.describe(message)
  local entry = {
    at = os.date("%H:%M:%S"),
    level = level,
    level_name = (level_styles[level] or level_styles[vim.log.levels.INFO]).name,
    summary = described.summary,
    detail = described.detail,
  }
  table.insert(M.history, entry)
  while #M.history > M.options.history_limit do
    table.remove(M.history, 1)
  end

  -- Headless Neovim has no window to draw into, and a user who asked for
  -- `vim.notify` has a notification plugin that should own the presentation.
  if M.options.style ~= "popup" or #vim.api.nvim_list_uis() == 0 then
    local text = "remote-mirror: " .. entry.summary
    if entry.detail and entry.detail ~= entry.summary then
      text = text .. "\n" .. entry.detail
    end
    vim.notify(text, level)
    return entry
  end

  open(entry)
  return entry
end

function M.messages()
  local lines = {}
  for _, entry in ipairs(M.history) do
    table.insert(lines, ("%s  %-5s  %s"):format(entry.at, entry.level_name, entry.summary))
    if entry.detail and entry.detail ~= entry.summary then
      for _, detail in ipairs(vim.split(entry.detail, "\n", { plain = true })) do
        if vim.trim(detail) ~= "" then
          table.insert(lines, "                 " .. vim.trim(detail))
        end
      end
    end
  end
  if #lines == 0 then
    lines = { "No remote-mirror messages yet." }
  end
  return lines
end

return M
