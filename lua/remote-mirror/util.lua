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

function M.shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.notify(message, level)
  vim.notify("remote-mirror: " .. message, level or vim.log.levels.INFO)
end

return M
