local Config = require("remote-mirror.config")
local Core = require("remote-mirror.core")
local Registry = require("remote-mirror.registry")
local util = require("remote-mirror.util")

local M = {}
M.__index = M

local workspace_keys = {
  "name",
  "host",
  "remote_root",
  "mirror_root",
  "source_root",
  "state_root",
  "tree_root",
}

function M.new(options)
  options = options or {}
  local registry_path = options.registry_path
    or util.join(vim.fn.stdpath("data"), "remote-mirror", "workspaces.json")
  local manager = setmetatable({
    options = options,
    registry = Registry.new(registry_path):load(),
    current = nil,
  }, M)

  for _, workspace in ipairs(options.workspaces or {}) do
    manager.registry:add(Config.normalize(vim.tbl_deep_extend("force", options, workspace)))
  end
  return manager
end

function M:workspace_options(workspace)
  local options = vim.deepcopy(self.options)
  options.workspaces = nil
  options.registry_path = nil
  for _, key in ipairs(workspace_keys) do
    if workspace[key] ~= nil then
      options[key] = workspace[key]
    end
  end
  return Config.normalize(options)
end

function M:add(workspace)
  local config = self:workspace_options(workspace)
  self.registry:add(config)
  return config
end

function M:list()
  return self.registry:list()
end

function M:connect(name)
  local workspace = self.registry.workspaces[name]
  assert(workspace, "remote-mirror: unknown workspace " .. name)
  if self.current then
    self.current:stop_watcher()
    self.current = nil
  end

  local core = Core.new(self:workspace_options(workspace))
  core:ensure_layout()
  core:pull()
  core:start_watcher()
  self.current = core
  vim.cmd.cd(vim.fn.fnameescape(core.config.source_root))
  return core
end

function M:require_current()
  assert(self.current, "remote-mirror: use :RemoteMirrorConnect first")
  return self.current
end

function M:stop()
  if self.current then
    self.current:stop_watcher()
  end
end

return M
