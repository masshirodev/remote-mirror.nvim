local State = require("remote-mirror.state")
local util = require("remote-mirror.util")

local M = {}

-- Screens reopen themselves in place after an operation, and a scratch buffer
-- keeps its name until it is wiped, so claiming a name a live buffer still
-- holds fails outright. The previous screen is removed before the new one
-- takes its name.
local function open_screen(name, filetype)
  for _, existing in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(existing) == name then
      vim.api.nvim_buf_delete(existing, { force = true })
    end
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].filetype = filetype
  vim.api.nvim_buf_set_name(buffer, name)
  return buffer
end

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

local function prompt_connection(manager, workspace, callback, edit_host)
  local function continue_with_host(host)
    local resolved = manager:resolve_ssh(host, workspace.ssh_command)
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
          local transfer = choice:match("^SCP") and "scp" or "rsync"
          local sudo_choices = transfer == "rsync" and {
            "Use remote sudo (ask for password)",
            "Use remote sudo (passwordless)",
            "Do not use remote sudo",
            "Cancel",
          } or { "Do not use remote sudo", "Cancel" }
          vim.ui.select(sudo_choices, {
            prompt = "Remote workspace permissions:",
          }, function(sudo_choice)
            if sudo_choice == nil or sudo_choice == "Cancel" then
              return
            end
            local remote_sudo = sudo_choice:match("^Use remote sudo") ~= nil
            local remote_sudo_auth = not remote_sudo and "passwordless"
              or (sudo_choice:match("passwordless") and "passwordless" or "password")
            local function finish(sudo_password)
              callback({
              host = host,
              user = user ~= "" and user or nil,
              port = port ~= "" and port or nil,
              auth = password ~= "" and "password" or "ssh",
              transfer = transfer,
              remote_sudo = remote_sudo,
              remote_sudo_auth = remote_sudo_auth,
              ssh_config_file = resolved.config_file,
              }, password, sudo_password)
            end
            if remote_sudo and remote_sudo_auth == "password" then
              local sudo_ok, sudo_password = pcall(vim.fn.inputsecret, "Remote sudo password: ")
              if not sudo_ok then
                util.notify(sudo_password, vim.log.levels.ERROR)
                return
              end
              if sudo_password == "" then
                util.notify("remote sudo password is required", vim.log.levels.ERROR)
                return
              end
              finish(sudo_password)
            else
              finish(nil)
            end
          end)
        end)
      end)
    end)
  end

  if edit_host then
    vim.ui.input({ prompt = "SSH host or alias: ", default = workspace.host }, function(host)
      host = host and vim.trim(host) or ""
      if host ~= "" then
        continue_with_host(host)
      end
    end)
  else
    continue_with_host(workspace.host)
  end
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
    vim.list_extend(lines, { "", "# Largest directories/subdirectories the rules above do not cover:" })
    for _, suggestion in ipairs(suggestions) do
      table.insert(lines, ("#   %10s  %s/"):format(util.format_bytes(suggestion.size), suggestion.path))
    end
    vim.list_extend(lines, { "#", "# Uncomment any of these to keep that directory on the server." })
    cursor_line = #lines + 1
    for _, suggestion in ipairs(suggestions) do
      table.insert(lines, ("# %s/"):format(suggestion.path))
    end
  end

  local buffer = open_screen("remote-mirror://ignore/" .. definition.name, "gitignore")
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

-- Guidance is written into the buffer so the keys are visible while editing,
-- but it is stripped before the rules are used. Without a marker the header
-- would be saved and then re-added on the next edit, growing every round trip.
local guidance_prefix = "# remote-mirror:"

local function ignore_file_contents(buffer)
  local kept = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
    if line:sub(1, #guidance_prefix) ~= guidance_prefix then
      table.insert(kept, line)
    end
  end
  -- The blank line separating the guidance from the rules is ours too, and a
  -- leading blank means nothing in a gitignore file, so both ends are trimmed
  -- to keep repeated edits byte-identical.
  while #kept > 0 and vim.trim(kept[#kept]) == "" do
    table.remove(kept)
  end
  while #kept > 0 and vim.trim(kept[1]) == "" do
    table.remove(kept, 1)
  end
  return #kept > 0 and (table.concat(kept, "\n") .. "\n") or ""
end

-- Saving means different things depending on where the editor was opened from,
-- so the caller decides: browsing holds the rules until a root is chosen, while
-- a registered workspace already has one and writes through to it.
local function open_ignore_rules_editor(options)
  local lines = {
    ("%s .remoteignore for %s"):format(guidance_prefix, options.path),
    ("%s gitignore-style patterns, one per line; these comments are not saved."):format(guidance_prefix),
    ("%s <leader>s or Ctrl-S %s, q discards them."):format(guidance_prefix, options.save_hint),
    "",
  }
  if options.seed and options.seed ~= "" then
    vim.list_extend(lines, vim.split((options.seed:gsub("\n+$", "")), "\n", { plain = true }))
  else
    vim.list_extend(lines, options.defaults)
  end

  local buffer = open_screen("remote-mirror://ignore-edit/" .. options.name, "gitignore")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(5, #lines), 0 })

  local function save()
    options.on_save(ignore_file_contents(buffer))
  end

  vim.keymap.set("n", "<leader>s", save, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "<C-s>", save, { buffer = buffer, nowait = true })
  vim.keymap.set("i", "<C-s>", function()
    vim.cmd.stopinsert()
    save()
  end, { buffer = buffer, nowait = true })
  vim.keymap.set("n", "q", options.on_close, { buffer = buffer, nowait = true })
  return buffer
end

local function ignore_defaults(manager, workspace, path)
  return manager:workspace_options(vim.tbl_extend("force", workspace, { remote_root = path })).default_ignore
end

-- A registered workspace has a root already, so its rules are read from it and
-- written straight back to it.
local function edit_workspace_ignore(manager, workspace, on_close)
  local password = manager.credentials[workspace.name]
  local path = workspace.remote_root
  util.notify("reading " .. path .. "/.remoteignore")
  manager:remote_ignore_at_async(workspace, password, path, function(ok, info)
    if not ok then
      util.notify(info, vim.log.levels.ERROR)
      on_close()
      return
    end
    open_ignore_rules_editor({
      name = workspace.name,
      path = path,
      seed = info.exists and info.contents or nil,
      defaults = ignore_defaults(manager, workspace, path),
      save_hint = "writes .remoteignore",
      on_save = function(contents)
        util.notify("writing " .. path .. "/.remoteignore")
        manager:write_remote_ignore_at_async(workspace, password, path, contents, function(write_ok, err)
          if not write_ok then
            util.notify(err, vim.log.levels.ERROR)
            return
          end
          util.notify("wrote " .. path .. "/.remoteignore")
          on_close()
        end)
      end,
      on_close = on_close,
    })
  end)
end

local function join_remote(directory, name)
  if directory == "/" then
    return "/" .. name
  end
  return directory .. "/" .. name
end

-- `rules` outlives each browser buffer, because the screen is rebuilt whenever
-- the editor hands control back and the draft must survive that.
local function open_remote_browser(manager, workspace, password, on_select, on_cancel, rules, start_path)
  local buffer = open_screen("remote-mirror://browse/" .. workspace.name, "remote-mirror-browser")
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
      ("Enter open   -  parent   .  use this path   i  type a path   e  edit .remoteignore   H  dotfiles: %s   r  refresh   q  cancel"):format(
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
  map("e", function()
    if state.loading or not state.path then
      return
    end
    local path = state.path
    local function back()
      open_remote_browser(manager, workspace, password, on_select, on_cancel, rules, path)
    end

    local function edit(seed)
      open_ignore_rules_editor({
        name = workspace.name,
        path = path,
        seed = seed,
        defaults = ignore_defaults(manager, workspace, path),
        save_hint = "keeps these rules for the workspace",
        on_save = function(contents)
          rules.contents = contents
          util.notify("rules kept; they are written when a project root is chosen")
          back()
        end,
        on_close = back,
      })
    end

    -- A draft already carries edits that were never written anywhere, so it
    -- wins over whatever this directory happens to hold.
    if rules.contents then
      edit(rules.contents)
      return
    end
    util.notify("reading " .. path .. "/.remoteignore")
    manager:remote_ignore_at_async(workspace, password, path, function(ok, info)
      if not ok then
        util.notify(info, vim.log.levels.ERROR)
        back()
        return
      end
      edit(info.exists and info.contents or nil)
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

  load(start_path)
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
      prompt_connection(manager, { host = host }, function(connection, password, sudo_password)
        local base = vim.tbl_extend("force", connection, { name = name, host = host })
        manager:set_sudo_password(name, sudo_password)
        local rules = {}
        open_remote_browser(manager, base, password, function(remote_root)
          local definition = vim.tbl_extend("force", base, { remote_root = remote_root })
          util.notify("inspecting remote workspace")
          manager:inspect_workspace_async(definition, password, function(inspect_ok, stats)
            if not inspect_ok then
              util.notify(stats, vim.log.levels.ERROR)
              return
            end
            -- Rules drafted while browsing belong to whichever root was chosen,
            -- so they are written there instead of any directory passed through.
            if rules.contents then
              confirm_estimate(manager, definition, password, rules.contents, true, reopen)
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
        end, reopen, rules)
      end)
    end)
  end)
end

-- Changing a host can make the registered root invalid. Keep the old
-- registration until the new endpoint has a usable directory, and let the
-- user choose a replacement instead of creating a path or transferring files
-- implicitly.
local function edit_workspace_connection(manager, workspace, connection, password, sudo_password, reopen)
  local candidate = vim.tbl_extend("force", {}, workspace, connection)

  local function save(remote_root)
    local update = vim.tbl_extend("force", {}, connection, { remote_root = remote_root })
    local ok, updated = pcall(manager.update_connection, manager, workspace.name, update)
    if not ok then
      util.notify(updated, vim.log.levels.ERROR)
      return
    end
    manager:set_password(workspace.name, password)
    manager:set_sudo_password(workspace.name, sudo_password)
    util.notify("updated connection for " .. workspace.name)
    reopen()
  end

  util.notify("checking " .. candidate.host .. ":" .. candidate.remote_root)
  manager:browse_remote_async(candidate, password, candidate.remote_root, function(ok)
    if ok then
      save(candidate.remote_root)
      return
    end

    vim.ui.select({ "Keep current path", "Choose a remote directory", "Cancel" }, {
      prompt = ("Could not validate %s on %s. Keep it or choose another directory?"):format(
        candidate.remote_root,
        candidate.host
      ),
    }, function(choice)
      if choice == "Keep current path" then
        save(candidate.remote_root)
        return
      end
      if choice ~= "Choose a remote directory" then
        return
      end
      open_remote_browser(
        manager,
        candidate,
        password,
        function(remote_root)
          save(remote_root)
        end,
        function() end,
        {},
        candidate.remote_root
      )
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
    "Edit the first column, or delete rows to skip those paths, then press <leader>s or Ctrl-S to apply.",
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

  local buffer = open_screen("remote-mirror://review/" .. workspace.name, "remote-mirror-review")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(7, #lines), 0 })

  local applying = false
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buffer,
    once = true,
    callback = function()
      -- Reopening the screen wipes the previous buffer, which must not cancel
      -- the review that replaced the one this buffer was showing.
      if not applying and manager.reviewing == reviewing then
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

    -- A deleted review row is an explicit choice to leave that path alone.
    -- This makes it practical to remove one or two rows without having to
    -- preserve every generated line in the scratch buffer.
    for _, change in ipairs(reviewing.plan) do
      if not actions[change.path] then
        actions[change.path] = "skip"
        counts.skip = counts.skip + 1
      end
    end
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
    "Enter connect   a add   e edit connection   i edit .remoteignore   d delete   r refresh   q close",
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

  local buffer = open_screen("remote-mirror://workspaces", "remote-mirror")
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
    if workspace.remote_sudo and workspace.remote_sudo_auth == "password" and not manager:has_sudo_password(workspace.name) then
      local ok, password = pcall(vim.fn.inputsecret, "Remote sudo password for " .. workspace.name .. ": ")
      if not ok then
        util.notify(password, vim.log.levels.ERROR)
        return
      end
      if password == "" then
        util.notify("remote sudo password is required", vim.log.levels.ERROR)
        return
      end
      manager:set_sudo_password(workspace.name, password)
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
    prompt_connection(manager, workspace, function(connection, password, sudo_password)
      manager:set_password(workspace.name, password)
      manager:set_sudo_password(workspace.name, sudo_password)
      edit_workspace_connection(manager, workspace, connection, password, sudo_password, reopen)
    end, true)
  end, { buffer = buffer, nowait = true })
  -- A registered workspace already has its root, so its rules are edited in
  -- place rather than by browsing back to it.
  vim.keymap.set("n", "i", function()
    local index = vim.api.nvim_win_get_cursor(0)[1] - 4
    local workspace = workspaces[index]
    if not workspace then
      return
    end
    edit_workspace_ignore(manager, workspace, reopen)
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

local status_markers = {
  conflict = "!",
  remote_changed = "~",
  remote_deleted = "x",
  absent = "↓",
  clean = " ",
}

M._edit_workspace_ignore = edit_workspace_ignore
M._open_remote_browser = open_remote_browser

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
    "↓ not downloaded    ~ changed on remote    x deleted on remote    ! conflict",
    "",
  }
  for _, path in ipairs(paths) do
    local status = State.file_status(core.state.data.files[path], core.state.data.conflicts[path])
    table.insert(lines, ("%s %s"):format(status_markers[status], path))
  end
  if #paths == 0 then
    table.insert(lines, "  This workspace has no files.")
  end

  local buffer = open_screen("remote-mirror://workspace/" .. core.config.name, "remote-mirror")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.api.nvim_set_current_buf(buffer)
  vim.api.nvim_win_set_cursor(0, { math.min(7, #lines), 0 })

  local function selected_path()
    return paths[vim.api.nvim_win_get_cursor(0)[1] - 6]
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
