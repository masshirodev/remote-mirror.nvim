local M = {}

function M.join(...)
  return vim.fs.normalize(table.concat({ ... }, "/"))
end

function M.ensure_dir(path)
  local ok, err = vim.uv.fs_mkdir(path, 448)
  if ok or (err and err:match("EEXIST")) then
    return
  end

  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    M.ensure_dir(parent)
    ok, err = vim.uv.fs_mkdir(path, 448)
    if ok or (err and err:match("EEXIST")) then
      return
    end
  end

  error(("could not create directory %s: %s"):format(path, err or "unknown error"))
end

function M.read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.write_file(path, content)
  M.ensure_dir(vim.fs.dirname(path))
  local temporary = path .. ".tmp"
  local file, err = io.open(temporary, "wb")
  if not file then
    error(("could not write %s: %s"):format(temporary, err))
  end
  file:write(content)
  file:close()

  local ok, rename_err = os.rename(temporary, path)
  if not ok then
    error(("could not replace %s: %s"):format(path, rename_err))
  end
end

function M.hash_file(path)
  local content = M.read_file(path)
  if content == nil then
    return nil
  end
  return vim.fn.sha256(content)
end

function M.is_file(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

function M.relative_path(root, path)
  root = vim.fs.normalize(root)
  path = vim.fs.normalize(path)
  if path == root then
    return ""
  end
  local prefix = root .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  return path:sub(#prefix + 1)
end

function M.walk_files(root)
  local files = {}

  local function visit(directory, prefix)
    local handle = vim.uv.fs_scandir(directory)
    if not handle then
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local relative = prefix == "" and name or (prefix .. "/" .. name)
      local absolute = M.join(directory, name)
      if kind == "directory" then
        visit(absolute, relative)
      elseif kind == "file" then
        files[relative] = M.hash_file(absolute)
      end
    end
  end

  visit(root, "")
  return files
end

function M.walk_directories(root)
  local directories = { root }

  local function visit(directory)
    local handle = vim.uv.fs_scandir(directory)
    if not handle then
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      if kind == "directory" then
        local path = M.join(directory, name)
        table.insert(directories, path)
        visit(path)
      end
    end
  end

  visit(root)
  return directories
end

-- Transfers rewrite files underneath open buffers, and Neovim only notices an
-- external write on its own when 'autoread' is set, so the mirror reloads its
-- own buffers. A modified buffer is never touched: its unsaved text is the only
-- copy of the user's work, so it is reported instead.
function M.reload_buffers(source_root, paths)
  local wanted
  if paths then
    wanted = {}
    for _, path in ipairs(paths) do
      wanted[M.join(source_root, path)] = true
    end
  end

  local stale = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buffer)
      local absolute = name ~= "" and vim.fs.normalize(name) or nil
      local relative = absolute and M.relative_path(source_root, absolute) or nil
      if relative and relative ~= "" and (not wanted or wanted[absolute]) then
        if vim.bo[buffer].modified then
          table.insert(stale, relative)
        else
          pcall(vim.api.nvim_buf_call, buffer, function()
            vim.cmd.edit({ mods = { emsg_silent = true } })
          end)
        end
      end
    end
  end

  table.sort(stale)
  return stale
end

-- The fraction is cut before any number conversion: `1700000000.9999999999`
-- does not survive a double intact and would otherwise round up to a second
-- that `stat -c %Y` never reports.
function M.signature(size, mtime)
  local seconds = tostring(mtime):match("^(%-?%d+)") or "0"
  return ("%d:%d"):format(tonumber(size) or 0, tonumber(seconds))
end

function M.shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.format_bytes(bytes)
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local value = tonumber(bytes) or 0
  local unit = 1
  while value >= 1024 and unit < #units do
    value = value / 1024
    unit = unit + 1
  end
  if unit == 1 then
    return ("%d %s"):format(value, units[unit])
  end
  return ("%.1f %s"):format(value, units[unit])
end

function M.notify(message, level)
  vim.notify("remote-mirror: " .. message, level or vim.log.levels.INFO)
end

return M
