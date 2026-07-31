local Ignore = require("remote-mirror.ignore")
local process = require("remote-mirror.process")
local util = require("remote-mirror.util")

local M = {}
M.__index = M

function M.new(config, runner)
  return setmetatable({
    config = config,
    run = runner or process.run,
  }, M)
end

function M:ssh_arguments()
  local arguments = {
    self.config.ssh_command,
  }
  if self.config.ssh_config_file then
    vim.list_extend(arguments, { "-F", self.config.ssh_config_file })
  end
  vim.list_extend(arguments, {
    "-o",
    "ConnectTimeout=" .. self.config.ssh_connect_timeout,
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=2",
    "-o",
    "NumberOfPasswordPrompts=1",
  })
  if self.config.port then
    vim.list_extend(arguments, { "-p", tostring(self.config.port) })
  end
  if self.config.user then
    vim.list_extend(arguments, { "-l", self.config.user })
  end
  if self.config.auth == "password" then
    vim.list_extend(arguments, {
      "-o",
      "PreferredAuthentications=password,keyboard-interactive",
      "-o",
      "PubkeyAuthentication=no",
    })
  end
  vim.list_extend(arguments, self.config.ssh_args)
  return arguments
end

function M:scp_arguments()
  local arguments = { self.config.scp_command }
  if self.config.ssh_config_file then
    vim.list_extend(arguments, { "-F", self.config.ssh_config_file })
  end
  vim.list_extend(arguments, {
    "-o",
    "ConnectTimeout=" .. self.config.ssh_connect_timeout,
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=2",
    "-o",
    "NumberOfPasswordPrompts=1",
  })
  if self.config.port then
    vim.list_extend(arguments, { "-P", tostring(self.config.port) })
  end
  if self.config.auth == "password" then
    vim.list_extend(arguments, {
      "-o",
      "PreferredAuthentications=password,keyboard-interactive",
      "-o",
      "PubkeyAuthentication=no",
    })
  end
  vim.list_extend(arguments, self.config.scp_args)
  return arguments
end

function M:process_options(options)
  options = options or {}
  if self.config.auth ~= "password" then
    return options
  end

  local helper = util.join(self.config.state_root, "askpass.sh")
  util.write_file(helper, [[#!/bin/sh
printf '%s\n' "$REMOTE_MIRROR_PASSWORD"
]])
  local ok, err = vim.uv.fs_chmod(helper, 448)
  assert(ok, ("remote-mirror: could not secure askpass helper: %s"):format(err or "unknown error"))

  options.env = vim.tbl_extend("force", options.env or {}, {
    DISPLAY = vim.env.DISPLAY or ":0",
    SSH_ASKPASS = helper,
    SSH_ASKPASS_REQUIRE = "force",
    REMOTE_MIRROR_PASSWORD = assert(self.config._password, "remote-mirror: password is unavailable"),
  })
  return options
end

function M:ssh(remote_command, options)
  local command = remote_command
  local process_options = options
  if self.config.remote_sudo then
    local sudo = self.config.remote_sudo_auth == "password" and "sudo -S -p '' " or "sudo -n "
    command = sudo .. "sh -c " .. util.shell_quote(remote_command)
    if self.config.remote_sudo_auth == "password" then
      process_options = vim.tbl_extend("force", {}, options or {}, {
        stdin = (self.config._sudo_password or "") .. "\n" .. ((options and options.stdin) or ""),
      })
    end
  end
  return self:ssh_raw(command, process_options)
end

function M:ssh_raw(remote_command, options)
  local command = self:ssh_arguments()
  vim.list_extend(command, { self.config.host, remote_command })
  return self.run(command, self:process_options(options))
end

function M:ssh_direct(remote_command, options)
  local sudo = self.config.remote_sudo_auth == "password" and "sudo -S -p '' " or "sudo -n "
  local process_options = options
  if self.config.remote_sudo_auth == "password" then
    process_options = vim.tbl_extend("force", {}, options or {}, {
      stdin = (self.config._sudo_password or "") .. "\n" .. ((options and options.stdin) or ""),
    })
  end
  return self:ssh_raw(sudo .. remote_command, process_options)
end

local function shell_sudo_denied(error_message)
  error_message = tostring(error_message):lower()
  return error_message:find("not allowed to execute", 1, true) ~= nil
    and error_message:find("sh %-c", 1, false) ~= nil
end

function M:ssh_with_direct_fallback(shell_command, direct_command, options)
  local ok, result = pcall(self.ssh, self, shell_command, options)
  if ok then
    return result
  end
  if self.config.remote_sudo and direct_command and shell_sudo_denied(result) then
    return self:ssh_direct(direct_command, options)
  end
  error(result, 0)
end

function M:prepare_rsync()
  if self.config.remote_sudo and self.config.remote_sudo_auth == "password" then
    self:ssh_raw("sudo -S -p '' -v", { stdin = (self.config._sudo_password or "") .. "\n" })
  end
end

function M:remote_spec(path)
  return self.config.host .. ":" .. path
end

function M:scp_remote_spec(path)
  local host = self.config.host
  if host:find(":", 1, true) and host:sub(1, 1) ~= "[" then
    host = "[" .. host .. "]"
  end
  if self.config.user then
    host = self.config.user .. "@" .. host
  end
  return host .. ":" .. path
end

function M:rsync_shell()
  local arguments = self:ssh_arguments()
  return table.concat(arguments, " ")
end

function M:rsync_remote_path()
  if self.config.remote_sudo then
    return "sudo -n " .. self.config.rsync_command
  end
  return self.config.rsync_command
end

function M:manifest()
  local command = ([[
set -eu
cd %s
%s . -type f -printf "%%s\t%%T@\t%%P\n"
]]):format(
    util.shell_quote(self.config.remote_root),
    util.shell_quote(self.config.remote_find_command)
  )
  local direct_command = ("%s %s -type f -printf \"%%s\\t%%T@\\t%%P\\n\""):format(
    util.shell_quote(self.config.remote_find_command),
    util.shell_quote(self.config.remote_root)
  )
  local result = self:ssh_with_direct_fallback(command, direct_command)
  local manifest = {}

  for line in result.stdout:gmatch("[^\r\n]+") do
    local size, mtime, path = line:match("^(%d+)\t([%d.]+)\t(.+)$")
    if size then
      manifest[path] = {
        size = tonumber(size),
        mtime = tonumber(mtime),
        -- `find -printf %T@` carries a fraction that `stat -c %Y` does not, so
        -- signatures are truncated to whole seconds and stay comparable
        -- whichever command observed the file.
        signature = util.signature(size, mtime),
      }
    end
  end
  return manifest
end

-- Browsing happens before a project root is chosen, so the path is passed in
-- instead of being read from the configured remote root.
function M:list_directory(path)
  local target = (path == nil or path == "") and '"$HOME"' or util.shell_quote(path)
  local command = ([[
set -eu
cd %s
pwd
%s -L . -mindepth 1 -maxdepth 1 -printf '%%y\t%%f\n' 2>/dev/null || true
]]):format(target, util.shell_quote(self.config.remote_find_command))
  local result = self:ssh(command)

  local root
  local entries = {}
  for line in result.stdout:gmatch("[^\r\n]+") do
    if not root then
      root = line
    else
      local kind, name = line:match("^(%a)\t(.+)$")
      if kind then
        table.insert(entries, {
          name = name,
          kind = kind == "d" and "directory" or "file",
        })
      end
    end
  end
  assert(
    root and root:sub(1, 1) == "/",
    "remote-mirror: could not read the remote directory listing"
  )

  table.sort(entries, function(left, right)
    if left.kind ~= right.kind then
      return left.kind == "directory"
    end
    return left.name < right.name
  end)

  root = root:gsub("/+$", "")
  return { path = root ~= "" and root or "/", entries = entries }
end

-- Only the handful of paths the user has open is polled, so one `stat` call
-- covers them without the whole-tree walk `manifest` needs. Paths that no
-- longer exist are simply absent from the reply.
function M:signatures(paths)
  if #paths == 0 then
    return {}
  end
  local quoted = {}
  for _, path in ipairs(paths) do
    table.insert(quoted, util.shell_quote(self.config.remote_root .. "/" .. path))
  end
  local command = ("%s -c '%%s\t%%Y\t%%n' -- %s 2>/dev/null || true"):format(
    util.shell_quote(self.config.remote_stat_command),
    table.concat(quoted, " ")
  )
  local result = self:ssh(command)

  local prefix = self.config.remote_root .. "/"
  local signatures = {}
  for line in result.stdout:gmatch("[^\r\n]+") do
    local size, mtime, name = line:match("^(%d+)\t(%d+)\t(.+)$")
    if name and name:sub(1, #prefix) == prefix then
      signatures[name:sub(#prefix + 1)] = util.signature(size, mtime)
    end
  end
  return signatures
end

function M:inspect(path)
  local absolute = self.config.remote_root .. "/" .. path
  local quoted = util.shell_quote(absolute)
  local command = ([[
if [ -f %s ]; then
  size=$(wc -c < %s)
  mtime=$(%s -c %%Y %s)
  hash=$(%s %s)
  hash=${hash%%%% *}
  printf "%%s\t%%s\t%%s\n" "$hash" "$size" "$mtime"
fi
]]):format(
    quoted,
    quoted,
    util.shell_quote(self.config.remote_stat_command),
    quoted,
    util.shell_quote(self.config.remote_sha256sum_command),
    quoted
  )
  local result = self:ssh(command)
  local hash, size, mtime = result.stdout:match("^(%x+)\t(%d+)\t(%d+)")
  if not hash then
    return nil
  end
  return {
    hash = hash,
    size = tonumber(size),
    mtime = tonumber(mtime),
    signature = util.signature(size, mtime),
  }
end

function M:hash_manifest()
  local command = ([[
set -eu
cd %s
%s . -type f -exec %s -- {} +
]]):format(
    util.shell_quote(self.config.remote_root),
    util.shell_quote(self.config.remote_find_command),
    util.shell_quote(self.config.remote_sha256sum_command)
  )
  local result = self:ssh(command)
  local hashes = {}
  for line in result.stdout:gmatch("[^\r\n]+") do
    local hash, path = line:match("^(%x+)%s+%*?(.+)$")
    if hash and path then
      hashes[path:gsub("^%./", "")] = hash
    end
  end
  return hashes
end

function M:remote_ignore()
  local root = util.shell_quote(self.config.remote_root)
  local result = self:ssh(("cd %s && if [ -f .remoteignore ]; then cat .remoteignore; fi"):format(root))
  return result.stdout
end

function M:remote_ignore_info()
  local root = util.shell_quote(self.config.remote_root)
  local result = self:ssh(
    ("cd %s && if [ -f .remoteignore ]; then printf 'exists\\n'; cat .remoteignore; else printf 'missing\\n'; fi"):format(
      root
    )
  )
  local marker, contents = result.stdout:match("^([^\r\n]+)\r?\n?(.*)$")
  return {
    exists = marker == "exists",
    contents = marker == "exists" and contents or "",
  }
end

function M:write_remote_ignore(contents)
  local root = util.shell_quote(self.config.remote_root)
  local command = (
    "cd %s && umask 022 && cat > .remoteignore.remote-mirror.tmp && mv .remoteignore.remote-mirror.tmp .remoteignore"
  ):format(root)
  self:ssh(command, { stdin = contents })
end

function M:_remote_ignore_rules(remote_contents)
  return remote_contents ~= nil and remote_contents or self:remote_ignore()
end

function M:_included(path, remote_contents)
  return not Ignore.is_ignored(path, self.config.default_ignore, remote_contents)
end

function M:_scp_estimate(remote_contents)
  local size, files = 0, 0
  for path, metadata in pairs(self:manifest()) do
    if self:_included(path, remote_contents) then
      size = size + metadata.size
      files = files + 1
    end
  end
  return { size = size, files = files }
end

function M:estimate(filter_path, remote_contents)
  if self.config.transfer == "scp" then
    return self:_scp_estimate(self:_remote_ignore_rules(remote_contents))
  end
  local destination = util.join(self.config.state_root, "estimate")
  util.ensure_dir(destination)
  self:prepare_rsync()
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--dry-run",
    "--stats",
    "--out-format=",
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    "--rsync-path=" .. self:rsync_remote_path(),
    "--filter=merge " .. filter_path,
    self:remote_spec(self.config.remote_root .. "/"),
    destination .. "/",
  })
  local options = self:process_options({
    env = { LC_ALL = "C" },
  })
  local result = self.run(command, options)
  local size = result.stdout:match("Total file size:%s*([%d,]+)%s+bytes")
  local files = result.stdout:match("Number of regular files transferred:%s*([%d,]+)")
  assert(size, "remote-mirror: rsync did not report an estimated size")
  return {
    size = tonumber((size:gsub(",", ""))),
    files = files and tonumber((files:gsub(",", ""))) or 0,
  }
end

-- One traversal reports the total, the file count, and the per-directory sizes
-- used to suggest ignore rules, because `du` already walks the whole tree.
function M:workspace_stats()
  local root = util.shell_quote(self.config.remote_root)
  local command = ([[
set -eu
cd %s
%s . -type f | wc -l
%s -b --max-depth=2 . 2>/dev/null || true
]]):format(
    root,
    util.shell_quote(self.config.remote_find_command),
    util.shell_quote(self.config.remote_du_command)
  )
  local result = self:ssh(command)

  local files, size
  local directories = {}
  for line in result.stdout:gmatch("[^\r\n]+") do
    if files == nil then
      files = tonumber(vim.trim(line))
    else
      local bytes, path = line:match("^(%d+)%s+(.+)$")
      if bytes then
        path = path:gsub("^%./", ""):gsub("/+$", "")
        if path == "." or path == "" then
          size = tonumber(bytes)
        else
          table.insert(directories, { path = path, size = tonumber(bytes) })
        end
      end
    end
  end
  assert(files and size, "remote-mirror: could not read remote workspace size")

  table.sort(directories, function(left, right)
    if left.size ~= right.size then
      return left.size > right.size
    end
    return left.path < right.path
  end)
  return {
    size = size,
    files = files,
    directories = directories,
  }
end

function M:pull(filter_path, protected)
  if self.config.transfer == "scp" then
    return self:_scp_pull(protected)
  end
  self:prepare_rsync()
  util.ensure_dir(self.config.source_root)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    "--rsync-path=" .. self:rsync_remote_path(),
    "--delete",
    "--filter=merge " .. filter_path,
    self:remote_spec(self.config.remote_root .. "/"),
    self.config.source_root .. "/",
  })
  return self.run(command, self:process_options())
end

function M:push(filter_path)
  if self.config.transfer == "scp" then
    return self:_scp_push()
  end
  self:prepare_rsync()
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    "--rsync-path=" .. self:rsync_remote_path(),
    "--delete",
    "--filter=merge " .. filter_path,
    self.config.source_root .. "/",
    self:remote_spec(self.config.remote_root .. "/"),
  })
  return self.run(command, self:process_options())
end

function M:changes(filter_path)
  if self.config.transfer == "scp" then
    return self:_scp_changes()
  end
  self:prepare_rsync()
  util.ensure_dir(self.config.source_root)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    "--rsync-path=" .. self:rsync_remote_path(),
    "--delete",
    "--dry-run",
    "--checksum",
    "--itemize-changes",
    "--out-format=%i\t%n",
    "--filter=merge " .. filter_path,
    self:remote_spec(self.config.remote_root .. "/"),
    self.config.source_root .. "/",
  })
  local result = self.run(command, self:process_options())
  local changes = {}
  for line in result.stdout:gmatch("[^\r\n]+") do
    local itemized, path = line:match("^([^\t]+)\t(.+)$")
    if itemized and path then
      if itemized:match("^%*deleting") and path:sub(-1) ~= "/" then
        table.insert(changes, {
          path = path,
          kind = "local_only",
          local_exists = true,
          remote_exists = false,
        })
      elseif itemized:sub(2, 2) == "f" then
        local local_exists = util.is_file(util.join(self.config.source_root, path))
        table.insert(changes, {
          path = path,
          kind = local_exists and "modified" or "remote_only",
          local_exists = local_exists,
          remote_exists = true,
        })
      end
    end
  end
  table.sort(changes, function(left, right)
    return left.path < right.path
  end)
  return changes
end

function M:download(path)
  local destination = util.join(self.config.source_root, path)
  util.ensure_dir(vim.fs.dirname(destination))
  local command
  if self.config.transfer == "scp" then
    command = self:scp_arguments()
    vim.list_extend(command, {
      self:scp_remote_spec(self.config.remote_root .. "/" .. path),
      destination,
    })
  else
    self:prepare_rsync()
    command = { self.config.rsync_command }
    vim.list_extend(command, self.config.rsync_args)
    vim.list_extend(command, {
      "--protect-args",
      "--rsh=" .. self:rsync_shell(),
      "--rsync-path=" .. self:rsync_remote_path(),
      self:remote_spec(self.config.remote_root .. "/" .. path),
      destination,
    })
  end
  return self.run(command, self:process_options())
end

function M:upload(path)
  local source = util.join(self.config.source_root, path)
  local remote_directory = vim.fs.dirname(self.config.remote_root .. "/" .. path)
  self:ssh("mkdir -p " .. util.shell_quote(remote_directory))

  local command
  if self.config.transfer == "scp" then
    command = self:scp_arguments()
    vim.list_extend(command, {
      source,
      self:scp_remote_spec(self.config.remote_root .. "/" .. path),
    })
  else
    self:prepare_rsync()
    command = { self.config.rsync_command }
    vim.list_extend(command, self.config.rsync_args)
    vim.list_extend(command, {
      "--protect-args",
      "--rsh=" .. self:rsync_shell(),
      "--rsync-path=" .. self:rsync_remote_path(),
      source,
      self:remote_spec(self.config.remote_root .. "/" .. path),
    })
  end
  return self.run(command, self:process_options())
end

function M:delete(path)
  return self:ssh("rm -f -- " .. util.shell_quote(self.config.remote_root .. "/" .. path))
end

function M:_scp_pull(protected)
  local remote_contents = self:_remote_ignore_rules()
  local remote = self:manifest()
  local local_files = util.walk_files(self.config.source_root)
  local paths = vim.tbl_keys(remote)
  local protected_paths = {}
  for _, path in ipairs(protected or {}) do
    protected_paths[path] = true
  end
  table.sort(paths)

  for _, path in ipairs(paths) do
    if self:_included(path, remote_contents) and not protected_paths[path] then
      self:download(path)
    end
  end
  for path in pairs(local_files) do
    if self:_included(path, remote_contents) and not protected_paths[path] and not remote[path] then
      local absolute = util.join(self.config.source_root, path)
      local removed, err = os.remove(absolute)
      assert(
        removed or not util.is_file(absolute),
        ("remote-mirror: could not delete local file %s: %s"):format(path, err or "unknown error")
      )
    end
  end
  return { code = 0, stdout = "", stderr = "" }
end

function M:_scp_push()
  local remote_contents = self:_remote_ignore_rules()
  local remote = self:manifest()
  local local_files = util.walk_files(self.config.source_root)
  local paths = vim.tbl_keys(local_files)
  table.sort(paths)

  for _, path in ipairs(paths) do
    if self:_included(path, remote_contents) then
      self:upload(path)
    end
  end
  for path in pairs(remote) do
    if self:_included(path, remote_contents) and not local_files[path] then
      self:delete(path)
    end
  end
  return { code = 0, stdout = "", stderr = "" }
end

function M:_scp_changes()
  local remote_contents = self:_remote_ignore_rules()
  local remote = self:manifest()
  local remote_hashes = self:hash_manifest()
  local local_files = util.walk_files(self.config.source_root)
  local paths = {}
  for path in pairs(remote) do
    paths[path] = true
  end
  for path in pairs(local_files) do
    paths[path] = true
  end

  local changes = {}
  for path in pairs(paths) do
    if self:_included(path, remote_contents) then
      local local_hash = local_files[path]
      local remote_metadata = remote[path]
      if local_hash and not remote_metadata then
        table.insert(changes, {
          path = path,
          kind = "local_only",
          local_exists = true,
          remote_exists = false,
        })
      elseif remote_metadata then
        local remote_hash = remote_hashes[path]
        if not local_hash or local_hash ~= remote_hash then
          table.insert(changes, {
            path = path,
            kind = local_hash and "modified" or "remote_only",
            local_exists = local_hash ~= nil,
            remote_exists = true,
            remote_hash = remote_hash,
          })
        end
      end
    end
  end
  table.sort(changes, function(left, right)
    return left.path < right.path
  end)
  return changes
end

return M
