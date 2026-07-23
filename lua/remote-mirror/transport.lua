local process = require("remote-mirror.process")
local util = require("remote-mirror.util")

local M = {}
M.__index = M

local manifest_script = [[
set -eu
cd %s
find . -type f -printf "%%s\t%%T@\t%%P\n"
]]

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
  local command = self:ssh_arguments()
  vim.list_extend(command, { self.config.host, remote_command })
  return self.run(command, self:process_options(options))
end

function M:remote_spec(path)
  return self.config.host .. ":" .. path
end

function M:rsync_shell()
  local arguments = self:ssh_arguments()
  return table.concat(arguments, " ")
end

function M:manifest()
  local command = manifest_script:format(util.shell_quote(self.config.remote_root))
  local result = self:ssh(command)
  local manifest = {}

  for line in result.stdout:gmatch("[^\r\n]+") do
    local size, mtime, path = line:match("^(%d+)\t([%d.]+)\t(.+)$")
    if size then
      manifest[path] = {
        size = tonumber(size),
        mtime = tonumber(mtime),
        signature = size .. ":" .. mtime,
      }
    end
  end
  return manifest
end

function M:inspect(path)
  local absolute = self.config.remote_root .. "/" .. path
  local quoted = util.shell_quote(absolute)
  local command = ([[
if [ -f %s ]; then
  size=$(wc -c < %s)
  mtime=$(stat -c %%Y %s)
  hash=$(sha256sum %s)
  hash=${hash%%%% *}
  printf "%%s\t%%s\t%%s\n" "$hash" "$size" "$mtime"
fi
]]):format(quoted, quoted, quoted, quoted)
  local result = self:ssh(command)
  local hash, size, mtime = result.stdout:match("^(%x+)\t(%d+)\t(%d+)")
  if not hash then
    return nil
  end
  return {
    hash = hash,
    size = tonumber(size),
    mtime = tonumber(mtime),
    signature = size .. ":" .. mtime,
  }
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

function M:estimate(filter_path)
  local destination = util.join(self.config.state_root, "estimate")
  util.ensure_dir(destination)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--dry-run",
    "--stats",
    "--out-format=",
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
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

function M:workspace_stats()
  local root = util.shell_quote(self.config.remote_root)
  local command = ([[
set -eu
cd %s
size=$(du -sb . | awk '{print $1}')
files=$(find . -type f | wc -l)
printf "%%s\t%%s\n" "$size" "$files"
]]):format(root)
  local result = self:ssh(command)
  local size, files = result.stdout:match("^(%d+)\t%s*(%d+)")
  assert(size and files, "remote-mirror: could not read remote workspace size")
  return {
    size = tonumber(size),
    files = tonumber(files),
  }
end

function M:pull(filter_path)
  util.ensure_dir(self.config.source_root)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    "--delete",
    "--filter=merge " .. filter_path,
    self:remote_spec(self.config.remote_root .. "/"),
    self.config.source_root .. "/",
  })
  return self.run(command, self:process_options())
end

function M:push(filter_path)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    "--delete",
    "--filter=merge " .. filter_path,
    self.config.source_root .. "/",
    self:remote_spec(self.config.remote_root .. "/"),
  })
  return self.run(command, self:process_options())
end

function M:changes(filter_path)
  util.ensure_dir(self.config.source_root)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
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
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    self:remote_spec(self.config.remote_root .. "/" .. path),
    destination,
  })
  return self.run(command, self:process_options())
end

function M:upload(path)
  local source = util.join(self.config.source_root, path)
  local remote_directory = vim.fs.dirname(self.config.remote_root .. "/" .. path)
  self:ssh("mkdir -p " .. util.shell_quote(remote_directory))

  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--protect-args",
    "--rsh=" .. self:rsync_shell(),
    source,
    self:remote_spec(self.config.remote_root .. "/" .. path),
  })
  return self.run(command, self:process_options())
end

function M:delete(path)
  return self:ssh("rm -f -- " .. util.shell_quote(self.config.remote_root .. "/" .. path))
end

return M
