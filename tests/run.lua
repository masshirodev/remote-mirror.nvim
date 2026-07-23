local failures = 0
local tests = {}

local function test(name, callback)
  table.insert(tests, { name = name, callback = callback })
end

local function assert_equal(expected, actual)
  if not vim.deep_equal(expected, actual) then
    error(("expected %s, got %s"):format(vim.inspect(expected), vim.inspect(actual)))
  end
end

test("normalizes configuration and workspace paths", function()
  local config = require("remote-mirror.config").normalize({
    name = "example",
    host = "server",
    remote_root = "/srv/example/",
    mirror_root = "/tmp/remote-mirror-test",
  })
  assert_equal("/srv/example", config.remote_root)
  assert_equal("/tmp/remote-mirror-test/source", config.source_root)
  assert_equal(true, config.upload_on_save)
end)

test("compiles defaults, re-includes, and protected paths", function()
  local rules = require("remote-mirror.ignore").compile(
    { "node_modules/", "*.log" },
    "!src/generated/schema.json\n.cache/\n",
    { "src/dirty.lua" }
  )
  assert(rules:find("- /src/dirty.lua", 1, true))
  assert(rules:find("+ /src/", 1, true))
  assert(rules:find("+ /src/generated/", 1, true))
  assert(rules:find("+ /src/generated/schema.json", 1, true))
  assert(rules:find("- node_modules/***", 1, true))
end)

test("quotes remote shell paths", function()
  assert_equal([['one'\''two']], require("remote-mirror.util").shell_quote("one'two"))
end)

test("parses a remote manifest", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = "/tmp/remote-mirror-test",
  })
  local runner = function()
    return {
      code = 0,
      stdout = "abc123\t42\t1700000000\tsrc/main.lua\n",
      stderr = "",
    }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  assert_equal({
    ["src/main.lua"] = {
      hash = "abc123",
      size = 42,
      mtime = 1700000000,
    },
  }, transport:manifest())
end)

test("builds a manifest with the real remote shell command", function()
  local root = vim.fn.tempname() .. " with quote's"
  local util = require("remote-mirror.util")
  util.ensure_dir(util.join(root, "src"))
  util.write_file(util.join(root, "src/main.lua"), "return true\n")
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = root,
    mirror_root = vim.fn.tempname(),
  })
  local runner = function(command)
    local result = vim.system({ "sh", "-c", command[3] }, { text = true }):wait()
    assert_equal(0, result.code)
    return result
  end
  local manifest = require("remote-mirror.transport").new(config, runner):manifest()
  assert_equal(12, manifest["src/main.lua"].size)
  assert_equal(64, #manifest["src/main.lua"].hash)
end)

test("refuses a push after the remote changed", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "main.lua"), "local changed = true\n")

  local State = require("remote-mirror.state")
  local state = State.new(config)
  state.data.files["main.lua"] = {
    remote_hash = "baseline",
    local_hash = "old-local",
    materialized = true,
  }

  local uploaded = false
  local transport = {
    manifest = function()
      return { ["main.lua"] = { hash = "remote-changed" } }
    end,
    upload = function()
      uploaded = true
    end,
  }
  local core = require("remote-mirror.core").new(config, {
    state = state,
    transport = transport,
  })
  local ok = core:push_file("main.lua", false)

  assert_equal(false, ok)
  assert_equal(false, uploaded)
  assert(state.data.conflicts["main.lua"])
end)

test("persists named workspaces", function()
  local path = vim.fn.tempname() .. "/workspaces.json"
  local registry = require("remote-mirror.registry").new(path)
  registry:add({
    name = "website",
    host = "server",
    remote_root = "/srv/website",
    mirror_root = "/tmp/website",
    source_root = "/tmp/website/source",
  })
  local loaded = require("remote-mirror.registry").new(path):load()
  assert_equal("server", loaded.workspaces.website.host)
  assert_equal("/srv/website", loaded.workspaces.website.remote_root)
end)

test("watcher sends external changes through the upload scheduler", function()
  local root = vim.fn.tempname()
  local util = require("remote-mirror.util")
  util.ensure_dir(root)
  util.write_file(util.join(root, "before.lua"), "before\n")
  local changed = {}
  local core = {
    config = {
      source_root = root,
      watch_debounce_ms = 0,
    },
    schedule_upload = function(_, path)
      changed[path] = true
    end,
  }
  local watcher = require("remote-mirror.watcher").new(core)
  watcher.stopped = false
  watcher.snapshot = util.walk_files(root)
  util.write_file(util.join(root, "before.lua"), "after\n")
  util.write_file(util.join(root, "created.lua"), "created\n")
  watcher:scan()
  os.remove(util.join(root, "before.lua"))
  watcher:scan()
  watcher:stop()
  assert_equal(true, changed["before.lua"])
  assert_equal(true, changed["created.lua"])
end)

test("records a conflict when both sides create the same path", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "same.txt"), "local\n")
  local transport = {
    manifest = function()
      return {
        ["same.txt"] = {
          hash = "remote-hash",
          size = 7,
          mtime = 1700000000,
        },
      }
    end,
  }
  local core = require("remote-mirror.core").new(config, { transport = transport })
  core:refresh()
  assert_equal("both_created", core.state.data.conflicts["same.txt"].kind)
end)

for _, item in ipairs(tests) do
  local ok, err = pcall(item.callback)
  if ok then
    print("ok - " .. item.name)
  else
    failures = failures + 1
    print("not ok - " .. item.name)
    print(err)
  end
end

if failures > 0 then
  vim.cmd.cquit(failures)
end
vim.cmd.quit()
