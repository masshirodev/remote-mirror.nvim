local util = require("remote-mirror.util")

local M = {}

local function prompt(label, callback)
  vim.ui.input({ prompt = label }, function(value)
    if value and value ~= "" then
      callback(value)
    end
  end)
end

local function add_workspace(manager, reopen)
  prompt("Workspace name: ", function(name)
    prompt("SSH host or alias: ", function(host)
      prompt("Remote project root: ", function(remote_root)
        local ok, workspace = pcall(manager.add, manager, {
          name = name,
          host = host,
          remote_root = remote_root,
        })
        if not ok then
          util.notify(workspace, vim.log.levels.ERROR)
          return
        end
        util.notify("added workspace " .. workspace.name)
        reopen()
      end)
    end)
  end)
end

function M.open(manager)
  local workspaces = manager:list()
  local lines = {
    "Remote Mirror Workspaces",
    "",
    "Enter  connect    a  add workspace    r  refresh    q  close",
    "",
  }
  for _, workspace in ipairs(workspaces) do
    local active = manager.current and manager.current.config.name == workspace.name
    table.insert(lines, ("%s %-24s %s:%s"):format(active and "*" or " ", workspace.name, workspace.host, workspace.remote_root))
  end
  if #workspaces == 0 then
    table.insert(lines, "  No workspaces yet. Press a to add one.")
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "remote-mirror"
  vim.api.nvim_buf_set_name(buffer, "remote-mirror://workspaces")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(5, #lines), 0 })

  local function reopen()
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
    M.open(manager)
  end

  local function connect()
    local index = vim.api.nvim_win_get_cursor(0)[1] - 4
    local workspace = workspaces[index]
    if not workspace then
      return
    end
    util.notify("connecting to " .. workspace.name)
    local ok, core = pcall(manager.connect, manager, workspace.name)
    if not ok then
      util.notify(core, vim.log.levels.ERROR)
      return
    end
    vim.api.nvim_buf_delete(buffer, { force = true })
    M.open_workspace(manager, core)
    util.notify("connected to workspace " .. workspace.name)
  end

  vim.keymap.set("n", "<CR>", connect, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "a", function()
    add_workspace(manager, reopen)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "r", reopen, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "q", "<Cmd>bdelete<CR>", { buffer = buffer, nowait = true })
end

function M.open_workspace(manager, core)
  local paths = vim.tbl_keys(core.state.data.files)
  table.sort(paths)
  local lines = {
    ("Remote Workspace: %s"):format(core.config.name),
    ("%s:%s"):format(core.config.host, core.config.remote_root),
    "",
    "Enter  open file    c  workspaces    p  pull    P  push    r  refresh",
    "",
  }
  for _, path in ipairs(paths) do
    local entry = core.state.data.files[path]
    table.insert(lines, ("%s %s"):format(entry.materialized and " " or "↓", path))
  end
  if #paths == 0 then
    table.insert(lines, "  This workspace has no files.")
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "remote-mirror"
  vim.api.nvim_buf_set_name(buffer, "remote-mirror://workspace/" .. core.config.name)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(6, #lines), 0 })

  local function selected_path()
    return paths[vim.api.nvim_win_get_cursor(0)[1] - 5]
  end

  vim.keymap.set("n", "<CR>", function()
    local path = selected_path()
    if not path then
      return
    end
    local ok, local_path = pcall(core.materialize, core, path)
    if not ok then
      util.notify(local_path, vim.log.levels.ERROR)
      return
    end
    vim.cmd.edit(vim.fn.fnameescape(local_path))
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "c", function()
    M.open(manager)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "p", function()
    vim.cmd.RemoteMirrorPull()
    M.open_workspace(manager, core)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "P", function()
    vim.cmd.RemoteMirrorPush()
    M.open_workspace(manager, core)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "r", function()
    vim.cmd.RemoteMirrorRefresh()
    M.open_workspace(manager, core)
  end, { buffer = buffer, nowait = true })
end

return M
