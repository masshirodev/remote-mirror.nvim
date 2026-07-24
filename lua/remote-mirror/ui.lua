local util = require("remote-mirror.util")

local M = {}

-- Pasted values often carry surrounding whitespace, which the stricter
-- configuration checks would otherwise reject.
local function prompt(label, callback)
  vim.ui.input({ prompt = label }, function(value)
    value = value and vim.trim(value) or ""
    if value ~= "" then
      callback(value)
    end
  end)
end

local function prompt_connection(manager, workspace, callback)
  local resolved = manager:resolve_ssh(workspace.host, workspace.ssh_command)
  if resolved.error and resolved.error ~= "" then
    util.notify("could not inspect SSH config; using standard defaults", vim.log.levels.WARN)
  end

  vim.ui.input({
    prompt = "SSH port (blank uses SSH config, then 22): ",
    default = tostring(workspace.port or resolved.port or 22),
  }, function(port)
    if port == nil then
      return
    end
    port = vim.trim(port)
    vim.ui.input({
      prompt = "SSH user (blank uses SSH config): ",
      default = workspace.user or resolved.user or "",
    }, function(user)
      if user == nil then
        return
      end
      user = vim.trim(user)

      local ok, password = pcall(
        vim.fn.inputsecret,
        "Password (blank uses SSH config, agent, or identity): "
      )
      if not ok then
        util.notify(password, vim.log.levels.ERROR)
        return
      end
      local current_transfer = workspace.transfer or "rsync"
      local preferred = current_transfer == "scp" and "SCP (fallback)" or "rsync (recommended)"
      local alternate = current_transfer == "scp" and "rsync (recommended)" or "SCP (fallback)"
      vim.ui.select({ preferred, alternate, "Cancel" }, {
        prompt = "File transfer method:",
      }, function(choice)
        if choice == nil or choice == "Cancel" then
          return
        end
        callback({
          user = user ~= "" and user or nil,
          port = port ~= "" and port or nil,
          auth = password ~= "" and "password" or "ssh",
          transfer = choice:match("^SCP") and "scp" or "rsync",
          ssh_config_file = resolved.config_file,
        }, password)
      end)
    end)
  end)
end

local function save_workspace(manager, definition, password, reopen)
  local ok, workspace = pcall(manager.add, manager, definition)
  if not ok then
    util.notify(workspace, vim.log.levels.ERROR)
    return
  end
  manager:set_password(workspace.name, password)
  util.notify("added workspace " .. workspace.name)
  reopen()
end

local function confirm_estimate(manager, definition, password, contents, write_ignore, reopen)
  util.notify("estimating filtered mirror size")
  manager:estimate_workspace_async(definition, password, contents, function(ok, estimate)
    if not ok then
      util.notify(estimate, vim.log.levels.ERROR)
      return
    end
    local action = write_ignore and "Write .remoteignore and add workspace" or "Add workspace"
    local message = ("Estimated mirror: %s across %s files. Continue?"):format(
      util.format_bytes(estimate.size),
      tostring(estimate.files)
    )
    vim.ui.select({ action, "Cancel" }, { prompt = message }, function(choice)
      if choice ~= action then
        return
      end
      if not write_ignore then
        save_workspace(manager, definition, password, reopen)
        return
      end
      manager:write_remote_ignore_async(definition, password, contents, function(write_ok, result)
        if not write_ok then
          util.notify(result, vim.log.levels.ERROR)
          return
        end
        save_workspace(manager, definition, password, reopen)
      end)
    end)
  end)
end

local function open_ignore_editor(manager, definition, password, stats, reopen)
  local config = manager:workspace_options(definition)
  local lines = {
    "# Remote Mirror ignore rules",
    "# Gitignore-style patterns, one per line.",
    "# Press <leader>s or Ctrl-S to estimate, write, and continue.",
    "",
  }
  vim.list_extend(lines, config.default_ignore)

  local suggestions = require("remote-mirror.ignore").suggest(
    stats and stats.directories,
    config.default_ignore,
    ""
  )
  local cursor_line = #lines
  if #suggestions > 0 then
    vim.list_extend(lines, { "", "# Largest directories the rules above do not cover:" })
    for _, suggestion in ipairs(suggestions) do
      table.insert(lines, ("#   %10s  %s/"):format(util.format_bytes(suggestion.size), suggestion.path))
    end
    vim.list_extend(lines, { "#", "# Uncomment any of these to keep that directory on the server." })
    cursor_line = #lines + 1
    for _, suggestion in ipairs(suggestions) do
      table.insert(lines, ("# %s/"):format(suggestion.path))
    end
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "gitignore"
  vim.api.nvim_buf_set_name(buffer, "remote-mirror://ignore/" .. definition.name)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(cursor_line, #lines), 0 })

  local function continue_with_rules()
    local rules = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    local contents = table.concat(rules, "\n") .. "\n"
    confirm_estimate(manager, definition, password, contents, true, reopen)
  end

  vim.keymap.set("n", "<leader>s", continue_with_rules, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "<C-s>", continue_with_rules, { buffer = buffer, nowait = true })
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd.stopinsert()
    continue_with_rules()
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "q", function()
    reopen()
  end, { buffer = buffer, nowait = true })
end

local browser_header_lines = 3

local function join_remote(directory, name)
  if directory == "/" then
    return "/" .. name
  end
  return directory .. "/" .. name
end

local function open_remote_browser(manager, workspace, password, on_select, on_cancel)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "remote-mirror-browser"
  vim.api.nvim_buf_set_name(buffer, "remote-mirror://browse/" .. workspace.name)
  vim.api.nvim_set_current_buf(buffer)

  local state = { path = nil, entries = {}, visible = {}, hidden = false, loading = false }

  local function set_lines(lines, cursor)
    if not vim.api.nvim_buf_is_valid(buffer) then
      return
    end
    vim.bo[buffer].modifiable = true
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    if cursor and vim.api.nvim_get_current_buf() == buffer then
      vim.api.nvim_win_set_cursor(0, { math.min(cursor, #lines), 0 })
    end
  end

  local function render(message)
    state.visible = {}
    for _, entry in ipairs(state.entries) do
      if state.hidden or entry.name:sub(1, 1) ~= "." then
        table.insert(state.visible, entry)
      end
    end

    local lines = {
      ("Remote path: %s"):format(state.path or "unknown"),
      ("Enter open   -  parent   .  use this path   i  type a path   H  dotfiles: %s   r  refresh   q  cancel"):format(
        state.hidden and "shown" or "hidden"
      ),
      "",
    }
    for _, entry in ipairs(state.visible) do
      table.insert(lines, ("  %s%s"):format(entry.name, entry.kind == "directory" and "/" or ""))
    end
    if message then
      table.insert(lines, "  " .. message)
    elseif #state.visible == 0 then
      table.insert(lines, "  This directory has no visible entries.")
    end
    set_lines(lines, browser_header_lines + 1)
  end

  local function load(path)
    if state.loading then
      return
    end
    state.loading = true
    set_lines({
      ("Remote path: %s"):format(path or "home directory"),
      "",
      "  listing directory",
    })
    manager:browse_remote_async(workspace, password, path, function(ok, listing)
      state.loading = false
      if not vim.api.nvim_buf_is_valid(buffer) then
        return
      end
      if not ok then
        util.notify(listing, vim.log.levels.ERROR)
        if state.path then
          render()
        else
          render("Could not read this directory. Press i to type a path, or q to cancel.")
        end
        return
      end
      state.path = listing.path
      state.entries = listing.entries
      render()
    end)
  end

  local function entry_under_cursor()
    if state.loading or vim.api.nvim_get_current_buf() ~= buffer then
      return nil
    end
    return state.visible[vim.api.nvim_win_get_cursor(0)[1] - browser_header_lines]
  end

  local function map(lhs, callback)
    vim.keymap.set("n", lhs, callback, { buffer = buffer, nowait = true })
  end

  map("<CR>", function()
    local entry = entry_under_cursor()
    if not entry then
      return
    end
    if entry.kind ~= "directory" then
      util.notify("the project root must be a directory", vim.log.levels.WARN)
      return
    end
    load(join_remote(state.path, entry.name))
  end)
  map("-", function()
    if state.loading or not state.path or state.path == "/" then
      return
    end
    load(vim.fs.dirname(state.path))
  end)
  map(".", function()
    if state.loading or not state.path then
      return
    end
    on_select(state.path)
  end)
  map("i", function()
    vim.ui.input({ prompt = "Remote path: ", default = state.path or "" }, function(value)
      if value == nil or value == "" then
        return
      end
      local trimmed = (value:gsub("/+$", ""))
      load(trimmed ~= "" and trimmed or "/")
    end)
  end)
  map("H", function()
    if state.loading then
      return
    end
    state.hidden = not state.hidden
    render()
  end)
  map("r", function()
    load(state.path)
  end)
  map("q", function()
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.api.nvim_buf_delete(buffer, { force = true })
    end
    on_cancel()
  end)

  load(nil)
end

-- A reused name rebinds the registration and hands the new endpoint the old
-- mirror, so the collision is settled before anything else is asked.
local function prompt_workspace_name(manager, callback)
  prompt("Workspace name: ", function(name)
    local existing = manager:get(name)
    if not existing then
      callback(name)
      return
    end

    local replace = ("Replace it (its mirror stays bound to %s:%s)"):format(
      existing.host,
      existing.remote_root
    )
    vim.ui.select({ "Choose another name", replace, "Cancel" }, {
      prompt = ("%s already points at %s:%s."):format(name, existing.host, existing.remote_root),
    }, function(choice)
      if choice == "Choose another name" then
        prompt_workspace_name(manager, callback)
      elseif choice == replace then
        callback(name)
      end
    end)
  end)
end

local function add_workspace(manager, reopen)
  prompt_workspace_name(manager, function(name)
    prompt("SSH host or alias: ", function(host)
      prompt_connection(manager, { host = host }, function(connection, password)
        local base = vim.tbl_extend("force", connection, { name = name, host = host })
        open_remote_browser(manager, base, password, function(remote_root)
          local definition = vim.tbl_extend("force", base, { remote_root = remote_root })
          util.notify("inspecting remote workspace")
          manager:inspect_workspace_async(definition, password, function(inspect_ok, stats)
            if not inspect_ok then
              util.notify(stats, vim.log.levels.ERROR)
              return
            end
            if stats.remote_ignore.exists then
              util.notify("found existing .remoteignore")
              confirm_estimate(
                manager,
                definition,
                password,
                stats.remote_ignore.contents,
                false,
                reopen
              )
              return
            end

            local large = stats.size >= 100 * 1024 * 1024 or stats.files >= 10000
            local configure = large and "Configure .remoteignore (recommended)"
              or "Configure .remoteignore"
            local prompt_text = ("Remote path contains %s across %s files; no .remoteignore exists."):format(
              util.format_bytes(stats.size),
              tostring(stats.files)
            )
            vim.ui.select({
              configure,
              "Continue with built-in ignores",
              "Cancel",
            }, { prompt = prompt_text }, function(choice)
              if choice == configure then
                open_ignore_editor(manager, definition, password, stats, reopen)
              elseif choice == "Continue with built-in ignores" then
                confirm_estimate(manager, definition, password, "", false, reopen)
              end
            end)
          end)
        end, reopen)
      end)
    end)
  end)
end

local function confirm(prompt_text, action, callback)
  vim.ui.select({ action, "Cancel" }, { prompt = prompt_text }, function(choice)
    if choice == action then
      callback()
    end
  end)
end

local function open_reconcile_editor(manager, workspace, reviewing, on_connected)
  local lines = {
    ("Review connection: %s"):format(workspace.name),
    "Edit only the first column, then press <leader>s or Ctrl-S to apply.",
    "",
    "pull = remote wins    push = local wins    skip = leave both untouched",
    "For a one-sided file, pull deletes local-only and push deletes remote-only.",
    "",
  }
  for _, change in ipairs(reviewing.plan) do
    table.insert(lines, ("%s\t%s\t%s"):format(change.default_action, change.kind, change.path))
  end
  if #reviewing.plan == 0 then
    table.insert(lines, "# No differences. Apply to connect without transferring files.")
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = "remote-mirror-review"
  vim.api.nvim_buf_set_name(buffer, "remote-mirror://review/" .. workspace.name)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(7, #lines), 0 })

  local applying = false
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      if not applying then
        manager:cancel_review()
      end
    end,
  })

  local function parse_actions()
    local actions = {}
    local counts = { pull = 0, push = 0, skip = 0 }
    local plan_paths = {}
    for _, change in ipairs(reviewing.plan) do
      plan_paths[change.path] = true
    end
    local edited = vim.api.nvim_buf_get_lines(buffer, 6, -1, false)
    for _, line in ipairs(edited) do
      if line ~= "" and line:sub(1, 1) ~= "#" then
        local action, _, path = line:match("^(%S+)\t([^\t]+)\t(.+)$")
        assert(action and path, "remote-mirror: each review line must keep its three tab-separated columns")
        assert(
          action == "pull" or action == "push" or action == "skip",
          "remote-mirror: review actions must be pull, push, or skip"
        )
        assert(plan_paths[path], "remote-mirror: review path was changed: " .. path)
        assert(actions[path] == nil, "remote-mirror: duplicate review path: " .. path)
        actions[path] = action
        counts[action] = counts[action] + 1
      end
    end
    assert(vim.tbl_count(actions) == #reviewing.plan, "remote-mirror: every changed path needs an action")
    return actions, counts
  end

  local function apply()
    local ok, actions, counts = pcall(parse_actions)
    if not ok then
      util.notify(actions, vim.log.levels.ERROR)
      return
    end
    local prompt_text = (
      "Apply review? pull %d, push %d, skip %d. Pull/push choices may overwrite or delete files."
    ):format(counts.pull, counts.push, counts.skip)
    confirm(prompt_text, "Apply reviewed changes", function()
      applying = true
      util.notify("applying reviewed connection")
      manager:apply_review_async(actions, function(apply_ok, result)
        if not apply_ok then
          applying = false
          util.notify(result, vim.log.levels.ERROR)
          return
        end
        if vim.api.nvim_buf_is_valid(buffer) then
          vim.api.nvim_buf_delete(buffer, { force = true })
        end
        local summary = result.result
        util.notify(
          ("connected; applied %d, skipped %d, conflicts %d"):format(
            summary.applied,
            summary.skipped,
            summary.conflicts
          )
        )
        on_connected(result.core)
      end)
    end)
  end

  vim.keymap.set("n", "<leader>s", apply, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "<C-s>", apply, { buffer = buffer, nowait = true })
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd.stopinsert()
    apply()
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "q", "<Cmd>bdelete<CR>", { buffer = buffer, nowait = true })
end

function M.open(manager)
  local workspaces = manager:list()
  local lines = {
    "Remote Mirror Workspaces",
    "",
    "Enter connect   a add   e edit connection   d delete   r refresh   q close",
    "",
  }
  for _, workspace in ipairs(workspaces) do
    local active = manager.current and manager.current.config.name == workspace.name
    table.insert(
      lines,
      ("%s %-24s %-5s %s@%s:%s %s"):format(
        active and "*" or " ",
        workspace.name,
        workspace.transfer or "rsync",
        workspace.user or "ssh-config",
        workspace.host,
        workspace.port or "config/22",
        workspace.remote_root
      )
    )
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
    local function connected(core)
      if vim.api.nvim_buf_is_valid(buffer) then
        vim.api.nvim_buf_delete(buffer, { force = true })
      end
      M.open_workspace(manager, core)
      util.notify("connected to workspace " .. workspace.name)
    end

    local function run(strategy)
      util.notify("connecting to " .. workspace.name)
      manager:connect_async(workspace.name, strategy, function(ok, core)
        if not ok then
          util.notify(core, vim.log.levels.ERROR)
          return
        end
        connected(core)
      end)
    end

    local function choose_strategy()
      if not manager:has_local_mirror(workspace.name) then
        confirm(
          "Create this local mirror from the authoritative remote workspace?",
          "Confirm initial pull",
          function()
            run("force_pull")
          end
        )
        return
      end

      vim.ui.select({
        "Force pull (remote wins)",
        "Review changed paths",
        "Force push (local wins)",
        "Cancel",
      }, {
        prompt = "A local mirror already exists. How should it reconcile with the remote workspace?",
      }, function(choice)
        if choice == "Force pull (remote wins)" then
          confirm(
            "Within the mirrored scope, overwrite differing local files and delete local-only files?",
            "Confirm force pull",
            function()
              run("force_pull")
            end
          )
        elseif choice == "Force push (local wins)" then
          confirm(
            "Within the mirrored scope, overwrite differing remote files and delete remote-only files?",
            "Confirm force push",
            function()
              run("force_push")
            end
          )
        elseif choice == "Review changed paths" then
          util.notify("comparing local and remote files")
          manager:review_connect_async(workspace.name, function(ok, result)
            if not ok then
              util.notify(result, vim.log.levels.ERROR)
              return
            end
            open_reconcile_editor(manager, workspace, result, connected)
          end)
        end
      end)
    end

    if workspace.auth == "password" and not manager:has_password(workspace.name) then
      local ok, password = pcall(vim.fn.inputsecret, "Password for " .. workspace.name .. ": ")
      if not ok then
        util.notify(password, vim.log.levels.ERROR)
        return
      end
      if password == "" then
        util.notify("password is required", vim.log.levels.ERROR)
        return
      end
      manager:set_password(workspace.name, password)
    end
    choose_strategy()
  end

  vim.keymap.set("n", "<CR>", connect, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "a", function()
    add_workspace(manager, reopen)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "e", function()
    local index = vim.api.nvim_win_get_cursor(0)[1] - 4
    local workspace = workspaces[index]
    if not workspace then
      return
    end
    prompt_connection(manager, workspace, function(connection, password)
      local ok, updated = pcall(manager.update_connection, manager, workspace.name, connection)
      if not ok then
        util.notify(updated, vim.log.levels.ERROR)
        return
      end
      manager:set_password(workspace.name, password)
      util.notify("updated connection for " .. workspace.name)
      reopen()
    end)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "d", function()
    local index = vim.api.nvim_win_get_cursor(0)[1] - 4
    local workspace = workspaces[index]
    if not workspace then
      return
    end
    local keep = "Remove registration, keep the local mirror"
    local purge = "Remove registration and delete the local mirror"
    vim.ui.select({ keep, purge, "Cancel" }, {
      prompt = ("Delete workspace %s?"):format(workspace.name),
    }, function(choice)
      if choice ~= keep and choice ~= purge then
        return
      end

      local function unregister()
        local ok, err = pcall(manager.remove, manager, workspace.name)
        if not ok then
          util.notify(err, vim.log.levels.ERROR)
          return
        end
        util.notify("deleted workspace registration " .. workspace.name)
        reopen()
      end

      if choice == keep then
        unregister()
        return
      end

      local ok, mirror_root = pcall(manager.mirror_path, manager, workspace.name)
      if not ok then
        util.notify(mirror_root, vim.log.levels.ERROR)
        return
      end
      confirm(
        ("Permanently delete %s and every local file in it?"):format(mirror_root),
        "Delete the mirror",
        function()
          local reset_ok, result = pcall(manager.reset_mirror, manager, workspace.name)
          if not reset_ok then
            util.notify(result, vim.log.levels.ERROR)
            return
          end
          if result.existed then
            util.notify("deleted the local mirror at " .. result.path, vim.log.levels.WARN)
          end
          unregister()
        end
      )
    end)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "r", reopen, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "q", "<Cmd>bdelete<CR>", { buffer = buffer, nowait = true })
end

function M.open_workspace(manager, core)
  local paths = vim.tbl_keys(core.state.data.files)
  table.sort(paths)
  local lines = {
    ("Remote Workspace: %s"):format(core.config.name),
    ("via %s | %s@%s:%s %s"):format(
      core.config.transfer,
      core.config.user or "ssh-config",
      core.config.host,
      core.config.port or "config/22",
      core.config.remote_root
    ),
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

  local function run_and_reopen(operation, success_message)
    util.notify("workspace operation started")
    core:enqueue(operation, function(ok, result)
      if not ok then
        util.notify(result, vim.log.levels.ERROR)
        return
      end
      if success_message then
        util.notify(success_message(result))
      end
      if vim.api.nvim_buf_is_valid(buffer) then
        M.open_workspace(manager, core)
      end
    end)
  end

  vim.keymap.set("n", "<CR>", function()
    local path = selected_path()
    if not path then
      return
    end
    core:enqueue(function()
      return core:materialize(path)
    end, function(ok, local_path)
      if not ok then
        util.notify(local_path, vim.log.levels.ERROR)
        return
      end
      vim.cmd.edit(vim.fn.fnameescape(local_path))
    end)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "c", function()
    M.open(manager)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "p", function()
    run_and_reopen(function()
      return core:pull()
    end, function(result)
      return ("pulled %d remote files"):format(result.files)
    end)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "P", function()
    run_and_reopen(function()
      return core:push()
    end, function(result)
      return ("pushed %d files; %d conflicts"):format(result.pushed, result.conflicts)
    end)
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "r", function()
    run_and_reopen(function()
      return core:refresh()
    end, function(result)
      return ("found %d remote changes; %d conflicts"):format(result.changed, result.conflicts)
    end)
  end, { buffer = buffer, nowait = true })
end

return M
