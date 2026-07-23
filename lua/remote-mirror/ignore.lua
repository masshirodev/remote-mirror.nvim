local M = {}

local function clean_pattern(pattern)
  pattern = vim.trim(pattern)
  if pattern == "" or pattern:sub(1, 1) == "#" then
    return nil
  end
  return pattern
end

local function anchored(pattern)
  local without_trailing_slash = pattern:gsub("/+$", "")
  local root_anchored = pattern:sub(1, 1) == "/"
    or without_trailing_slash:find("/", 1, true) ~= nil
  pattern = pattern:gsub("^/", "")
  if pattern:sub(-1) == "/" then
    pattern = pattern .. "***"
  end
  return root_anchored and ("/" .. pattern) or pattern
end

local function parent_patterns(pattern)
  local parents = {}
  local current = pattern:gsub("^/", ""):gsub("/+$", "")
  current = current:match("^(.*)/[^/]+$")
  while current and current ~= "" do
    table.insert(parents, 1, "+ /" .. current .. "/")
    current = current:match("^(.*)/[^/]+$")
  end
  return parents
end

function M.compile(defaults, remote_contents, protected)
  local includes = {}
  local excludes = {}
  local seen = {}

  local function add_rule(raw)
    local pattern = clean_pattern(raw)
    if not pattern then
      return
    end
    if pattern:sub(1, 1) == "!" then
      pattern = pattern:sub(2)
      for _, parent in ipairs(parent_patterns(pattern)) do
        if not seen[parent] then
          table.insert(includes, parent)
          seen[parent] = true
        end
      end
      table.insert(includes, "+ " .. anchored(pattern))
    else
      table.insert(excludes, "- " .. anchored(pattern))
    end
  end

  for _, pattern in ipairs(defaults) do
    add_rule(pattern)
  end
  for line in (remote_contents or ""):gmatch("[^\r\n]+") do
    add_rule(line)
  end

  local rules = {}
  for _, path in ipairs(protected or {}) do
    table.insert(rules, "- /" .. path)
  end
  vim.list_extend(rules, includes)
  vim.list_extend(rules, excludes)
  return table.concat(rules, "\n") .. "\n"
end

return M
