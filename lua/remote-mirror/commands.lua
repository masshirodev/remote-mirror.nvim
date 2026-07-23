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

function M.register(manager)
  local group = vim.api.nvim_create_augroup("RemoteMirror", { clear = true })
  local command_names = {
    "RemoteMirrorConnect",
    "RemoteMirrorPull",
    "RemoteMirrorPush",
    "RemoteMirrorRefresh",
    "RemoteMirrorConflicts",
    "RemoteMirrorResolve",
  }
  for _, name in ipairs(command_names) do
    pcall(vim.api.nvim_del_user_command, name)
  end

  vim.api.nvim_create_user_command("RemoteMirrorConnect", safely(function()
    require("remote-mirror.ui").open(manager)
  end), { desc = "Open the remote workspace connection screen" })

  vim.api.nvim_create_user_command("RemoteMirrorPull", safely(function()
    local result = manager:require_current():pull()
    util.notify(("pulled %d remote files; protected %d local changes"):format(result.files, #result.protected))
  end), { desc = "Pull the active remote workspace" })

  vim.api.nvim_create_user_command("RemoteMirrorPush", safely(function()
    local result = manager:require_current():push()
    util.notify(("pushed %d files; %d conflicts"):format(result.pushed, result.conflicts))
  end), { desc = "Push changes in the active remote workspace" })

  vim.api.nvim_create_user_command("RemoteMirrorRefresh", safely(function()
    local result = manager:require_current():refresh()
    util.notify(("found %d remote changes; %d conflicts"):format(result.changed, result.conflicts))
  end), { desc = "Refresh the active remote manifest" })

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
    manager:require_current():resolve(path, strategy)
    util.notify(("resolved %s using %s"):format(path, strategy))
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

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      manager:stop()
    end,
    desc = "Stop remote-mirror workspace watchers",
  })
end

return M
