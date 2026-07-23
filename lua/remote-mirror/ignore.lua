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

local function glob_to_lua(glob)
  local output = { "^" }
  local index = 1
  while index <= #glob do
    local character = glob:sub(index, index)
    local pair = glob:sub(index, index + 1)
    if pair == "**" then
      table.insert(output, ".*")
      index = index + 2
    elseif character == "*" then
      table.insert(output, "[^/]*")
      index = index + 1
    elseif character == "?" then
      table.insert(output, "[^/]")
      index = index + 1
    else
      table.insert(output, (character:gsub("([%^%$%(%)%%%.%[%]%+%-])", "%%%1")))
      index = index + 1
    end
  end
  table.insert(output, "$")
  return table.concat(output)
end

local function glob_matches(value, glob)
  if value:match(glob_to_lua(glob)) then
    return true
  end
  local without_globstar = glob:gsub("%*%*/", "")
  return without_globstar ~= glob and value:match(glob_to_lua(without_globstar)) ~= nil
end

local function rule_matches(path, raw_pattern)
  local pattern = raw_pattern:gsub("^/", "")
  local directory = pattern:sub(-1) == "/"
  pattern = pattern:gsub("/+$", "")
  local rooted = raw_pattern:sub(1, 1) == "/" or pattern:find("/", 1, true) ~= nil

  if rooted then
    if glob_matches(path, pattern) then
      return true
    end
    if directory then
      local prefix = path
      while prefix:find("/", 1, true) do
        prefix = prefix:match("^(.*)/[^/]+$")
        if prefix and glob_matches(prefix, pattern) then
          return true
        end
      end
    end
    return false
  end

  for component in path:gmatch("[^/]+") do
    if glob_matches(component, pattern) then
      return true
    end
  end
  return false
end

function M.is_ignored(path, defaults, remote_contents)
  path = path:gsub("^%./", ""):gsub("/+$", "")
  local ignored = false

  local function apply(raw)
    local pattern = clean_pattern(raw)
    if not pattern then
      return
    end
    local negated = pattern:sub(1, 1) == "!"
    if negated then
      pattern = pattern:sub(2)
    end
    if pattern ~= "" and rule_matches(path, pattern) then
      ignored = not negated
    end
  end

  for _, pattern in ipairs(defaults or {}) do
    apply(pattern)
  end
  for line in (remote_contents or ""):gmatch("[^\r\n]+") do
    apply(line)
  end
  return ignored
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
