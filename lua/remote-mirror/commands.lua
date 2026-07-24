local util = require("remote-mirror.util")

local M = {}

local function safely(callback)
  return function(options)
    local ok, result = pcall(callback, options)
    if not ok then
      util.notify(result, vim.log.levels.ERROR)
    end
  end
end

local function enqueue(core, operation, on_success)
  core:enqueue(operation, function(ok, result)
    if not ok then
      util.notify(result, vim.log.levels.ERROR)
      return
    end
    on_success(result)
  end)
end

function M.register(manager)
  local group = vim.api.nvim_create_augroup("RemoteMirror", { clear = true })
  local command_names = {
    "RemoteMirrorConnect",
    "RemoteMirrorDisconnect",
    "RemoteMirrorReset",
    "RemoteMirrorPull",
    "RemoteMirrorPush",
    "RemoteMirrorRefresh",
    "RemoteMirrorPoll",
    "RemoteMirrorConflicts",
    "RemoteMirrorResolve",
  }
  for _, name in ipairs(command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end

  vim.api.nvim_create_user_command("RemoteMirrorConnect", safely(function()
    require("remote-mirror.ui").open(manager)
  end), { desc = "Open the remote workspace connection screen" })

  vim.api.nvim_create_user_command("RemoteMirrorDisconnect", safely(function(options)
    local result = manager:disconnect(options.bang)
    if result.pending > 0 then
      util.notify(
        ("disconnected %s; discarded %d pending upload(s)"):format(result.name, result.pending),
        vim.log.levels.WARN
      )
      return
    end
    util.notify("disconnected " .. result.name)
  end), {
    bang = true,
    desc = "Disconnect the active remote workspace, keeping its mirror on disk",
  })

  vim.api.nvim_create_user_command("RemoteMirrorReset", safely(function(options)
    local name = vim.trim(options.args)
    local result = manager:reset_mirror(name)
    if not result.existed then
      util.notify(("%s has no local mirror at %s"):format(name, result.path))
      return
    end
    util.notify(("deleted the local mirror at %s"):format(result.path), vim.log.levels.WARN)
  end), {
    nargs = 1,
    complete = function(lead)
      local names = {}
      for _, workspace in ipairs(manager:list()) do
        if workspace.name:sub(1, #lead) == lead then
          table.insert(names, workspace.name)
        end
      end
      return names
    end,
    desc = "Delete a workspace's local mirror, keeping its registration",
  })

  vim.api.nvim_create_user_command("RemoteMirrorPull", safely(function()
    local core = manager:require_current()
    enqueue(core, function()
      return core:pull()
    end, function(result)
      util.notify(("pulled %d remote files; protected %d local changes"):format(result.files, #result.protected))
    end)
  end), { desc = "Pull the active remote workspace" })

  vim.api.nvim_create_user_command("RemoteMirrorPush", safely(function()
    local core = manager:require_current()
    enqueue(core, function()
      return core:push()
    end, function(result)
      util.notify(("pushed %d files; %d conflicts"):format(result.pushed, result.conflicts))
    end)
  end), { desc = "Push changes in the active remote workspace" })

  vim.api.nvim_create_user_command("RemoteMirrorRefresh", safely(function()
    local core = manager:require_current()
    enqueue(core, function()
      return core:refresh()
    end, function(result)
      util.notify(("found %d remote changes; %d conflicts"):format(result.changed, result.conflicts))
    end)
  end), { desc = "Refresh the active remote manifest" })

  vim.api.nvim_create_user_command("RemoteMirrorPoll", safely(function()
    local scheduled, reason = manager:require_current():schedule_poll()
    if not scheduled then
      util.notify(reason)
    end
  end), { desc = "Check open workspace files for remote changes" })

  vim.api.nvim_create_user_command("RemoteMirrorConflicts", safely(function()
    local conflicts = manager:require_current().state.data.conflicts
    if vim.tbl_isempty(conflicts) then
      util.notify("no conflicts")
      return
    end
    vim.notify(vim.inspect(conflicts), vim.log.levels.WARN, { title = "remote-mirror conflicts" })
  end), { desc = "Show remote mirror conflicts" })

  vim.api.nvim_create_user_command("RemoteMirrorResolve", safely(function(options)
    local path, strategy = options.args:match("^(%S+)%s+(%S+)$")
    assert(path and strategy, "usage: RemoteMirrorResolve <path> <pull|push>")
    local core = manager:require_current()
    enqueue(core, function()
      core:resolve(path, strategy)
      return true
    end, function()
      util.notify(("resolved %s using %s"):format(path, strategy))
    end)
  end), {
    nargs = "+",
    desc = "Resolve a conflict with the local or remote version",
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(event)
      local core = manager.current
      if not core or not core.config.upload_on_save then
        return
      end
      local path = vim.api.nvim_buf_get_name(event.buf)
      local relative = util.relative_path(core.config.source_root, path)
      if relative and relative ~= "" then
        core:schedule_upload(relative)
      end
    end,
    desc = "Upload saved remote-mirror files",
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      local core = manager.current
      if core and core.config.poll_on_focus then
        core:schedule_poll()
      end
    end,
    desc = "Check open remote-mirror files when Neovim regains focus",
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      manager:stop()
    end,
    desc = "Stop remote-mirror workspace watchers",
  })
end

return M
