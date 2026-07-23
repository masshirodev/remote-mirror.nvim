local process = require("remote-mirror.process")
local util = require("remote-mirror.util")

local M = {}
M.__index = M

local manifest_script = [[
set -eu
cd %s
find . -type f -exec sh -c '
  for file do
    relative=${file#./}
    size=$(wc -c < "$file")
    mtime=$(stat -c %%Y "$file")
    hash=$(sha256sum "$file")
    hash=${hash%%%% *}
    printf "%%s\t%%s\t%%s\t%%s\n" "$hash" "$size" "$mtime" "$relative"
  done
' sh {} +
]]

function M.new(config, runner)
  return setmetatable({
    config = config,
    run = runner or process.run,
  }, M)
end

function M:ssh(remote_command, options)
  return self.run({ self.config.ssh_command, self.config.host, remote_command }, options)
end

function M:remote_spec(path)
  return self.config.host .. ":" .. util.shell_quote(path)
end

function M:manifest()
  local command = manifest_script:format(util.shell_quote(self.config.remote_root))
  local result = self:ssh(command)
  local manifest = {}

  for line in result.stdout:gmatch("[^\r\n]+") do
    local hash, size, mtime, path = line:match("^(%x+)\t(%d+)\t(%d+)\t(.+)$")
    if hash then
      manifest[path] = {
        hash = hash,
        size = tonumber(size),
        mtime = tonumber(mtime),
      }
    end
  end
  return manifest
end

function M:remote_ignore()
  local root = util.shell_quote(self.config.remote_root)
  local result = self:ssh(("cd %s && if [ -f .remoteignore ]; then cat .remoteignore; fi"):format(root))
  return result.stdout
end

function M:pull(filter_path)
  util.ensure_dir(self.config.source_root)
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    "--delete",
    "--filter=merge " .. filter_path,
    self:remote_spec(self.config.remote_root .. "/"),
    self.config.source_root .. "/",
  })
  return self.run(command)
end

function M:download(path)
  local destination = util.join(self.config.source_root, path)
  util.ensure_dir(vim.fs.dirname(destination))
  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    self:remote_spec(self.config.remote_root .. "/" .. path),
    destination,
  })
  return self.run(command)
end

function M:upload(path)
  local source = util.join(self.config.source_root, path)
  local remote_directory = vim.fs.dirname(self.config.remote_root .. "/" .. path)
  self:ssh("mkdir -p " .. util.shell_quote(remote_directory))

  local command = { self.config.rsync_command }
  vim.list_extend(command, self.config.rsync_args)
  vim.list_extend(command, {
    source,
    self:remote_spec(self.config.remote_root .. "/" .. path),
  })
  return self.run(command)
end

function M:delete(path)
  return self:ssh("rm -f -- " .. util.shell_quote(self.config.remote_root .. "/" .. path))
end

return M
