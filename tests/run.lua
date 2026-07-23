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

local function assert_contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return
    end
  end
  error(("expected %s to contain %s"):format(vim.inspect(values), vim.inspect(expected)))
end

local function find_prefixed(values, prefix)
  for _, value in ipairs(values) do
    if value:sub(1, #prefix) == prefix then
      return value
    end
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
  assert_equal(nil, config.port)
  assert_equal("/tmp/remote-mirror-test/source", config.source_root)
  assert_equal(true, config.upload_on_save)
end)

test("normalizes a workspace-specific SSH port", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    port = "65002",
    remote_root = "/srv/example",
    mirror_root = "/tmp/remote-mirror-test",
  })
  assert_equal(65002, config.port)
end)

test("normalizes SCP and command overrides without restoring default arguments", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    transfer = "scp",
    ssh_command = "/opt/bin/ssh",
    ssh_args = { "-o", "Compression=yes" },
    scp_command = "/opt/bin/scp",
    scp_args = {},
    rsync_args = {},
  })
  assert_equal("scp", config.transfer)
  assert_equal("/opt/bin/ssh", config.ssh_command)
  assert_equal({ "-o", "Compression=yes" }, config.ssh_args)
  assert_equal("/opt/bin/scp", config.scp_command)
  assert_equal({}, config.scp_args)
  assert_equal({}, config.rsync_args)
end)

test("preserves workspace-specific argument-list overrides during setup", function()
  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
    scp_args = { "-O" },
    workspaces = {
      {
        name = "website",
        host = "server",
        remote_root = "/srv/example",
        transfer = "scp",
        scp_args = {},
      },
    },
  })
  assert_equal({}, manager.registry.workspaces.website.scp_args)
end)

test("resolves SSH config defaults", function()
  local runner = function(command)
    assert_equal({ "ssh", "-G", "example" }, command)
    return {
      code = 0,
      stdout = table.concat({
        "host example",
        "hostname server.example.test",
        "user deploy",
        "port 65002",
        "identityfile ~/.ssh/example",
      }, "\n"),
      stderr = "",
    }
  end
  local resolved = require("remote-mirror.ssh_config").resolve("ssh", "example", runner)
  assert_equal("deploy", resolved.user)
  assert_equal(65002, resolved.port)
  assert_equal("~/.ssh/example", resolved.identity_files[1])
end)

test("bypasses a broken system SSH config while preserving user config", function()
  local calls = {}
  local runner = function(command)
    table.insert(calls, command)
    if #calls == 1 then
      return {
        code = 255,
        stdout = "",
        stderr = "Bad owner or permissions on /etc/ssh/ssh_config.d/example.conf",
      }
    end
    return {
      code = 0,
      stdout = "hostname server\nuser deploy\nport 65002\n",
      stderr = "",
    }
  end
  local resolved = require("remote-mirror.ssh_config").resolve("ssh", "example", runner)
  assert_equal({ "ssh", "-G", "example" }, calls[1])
  assert_equal("-F", calls[2][2])
  assert(calls[2][3] == "/dev/null" or calls[2][3]:match("/%.ssh/config$"))
  assert_equal(calls[2][3], resolved.config_file)
  assert_equal("deploy", resolved.user)
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

test("matches ignore rules locally for SCP transfers", function()
  local ignore = require("remote-mirror.ignore")
  local defaults = { "node_modules/", "*.log", "/root-only.txt", "dist/" }
  local remote = table.concat({
    "src/generated/",
    "!src/generated/schema.json",
  }, "\n")
  assert_equal(true, ignore.is_ignored("node_modules/package/index.js", defaults, remote))
  assert_equal(true, ignore.is_ignored("src/node_modules/index.js", defaults, remote))
  assert_equal(true, ignore.is_ignored("src/debug.log", defaults, remote))
  assert_equal(true, ignore.is_ignored("root-only.txt", defaults, remote))
  assert_equal(false, ignore.is_ignored("src/root-only.txt", defaults, remote))
  assert_equal(true, ignore.is_ignored("src/generated/other.json", defaults, remote))
  assert_equal(false, ignore.is_ignored("src/generated/schema.json", defaults, remote))
  assert_equal(false, ignore.is_ignored("src/main.lua", defaults, remote))
end)

test("quotes remote shell paths", function()
  assert_equal([['one'\''two']], require("remote-mirror.util").shell_quote("one'two"))
end)

test("formats remote workspace sizes", function()
  local util = require("remote-mirror.util")
  assert_equal("512 B", util.format_bytes(512))
  assert_equal("1.5 GiB", util.format_bytes(1610612736))
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
      stdout = "42\t1700000000.0000000000\tsrc/main.lua\n",
      stderr = "",
    }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  assert_equal({
    ["src/main.lua"] = {
      size = 42,
      mtime = 1700000000,
      signature = "42:1700000000.0000000000",
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
    local result = vim.system({ "sh", "-c", command[#command] }, { text = true }):wait()
    assert_equal(0, result.code)
    return result
  end
  local manifest = require("remote-mirror.transport").new(config, runner):manifest()
  assert_equal(12, manifest["src/main.lua"].size)
  assert(manifest["src/main.lua"].signature:match("^12:%d+%.%d+$"))
end)

test("hashes only a specifically inspected remote file", function()
  local root = vim.fn.tempname() .. " with quote's"
  local util = require("remote-mirror.util")
  util.ensure_dir(root)
  util.write_file(util.join(root, "main.lua"), "return true\n")
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = root,
    mirror_root = vim.fn.tempname(),
  })
  local runner = function(command)
    local result = vim.system({ "sh", "-c", command[#command] }, { text = true }):wait()
    assert_equal(0, result.code)
    return result
  end
  local inspected = require("remote-mirror.transport").new(config, runner):inspect("main.lua")
  assert_equal(12, inspected.size)
  assert_equal(64, #inspected.hash)
end)

test("parses a remote hash manifest in one SSH operation", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    remote_find_command = "/opt/bin/gfind",
    remote_sha256sum_command = "/opt/bin/gsha256sum",
  })
  local captured
  local runner = function(command)
    captured = command
    return {
      code = 0,
      stdout = table.concat({
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ./src/main.lua",
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *./file with spaces.txt",
      }, "\n"),
      stderr = "",
    }
  end
  local hashes = require("remote-mirror.transport").new(config, runner):hash_manifest()
  assert(captured[#captured]:find("/opt/bin/gfind", 1, true))
  assert(captured[#captured]:find("/opt/bin/gsha256sum", 1, true))
  assert_equal(64, #hashes["src/main.lua"])
  assert_equal(64, #hashes["file with spaces.txt"])
end)

test("reads remote workspace size and file count", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local runner = function()
    return {
      code = 0,
      stdout = "1610612736\t35369\n",
      stderr = "",
    }
  end
  local stats = require("remote-mirror.transport").new(config, runner):workspace_stats()
  assert_equal(1610612736, stats.size)
  assert_equal(35369, stats.files)
end)

test("detects an existing remote ignore file", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local runner = function()
    return {
      code = 0,
      stdout = "exists\nuploads/\ncache/\n",
      stderr = "",
    }
  end
  local info = require("remote-mirror.transport").new(config, runner):remote_ignore_info()
  assert_equal(true, info.exists)
  assert_equal("uploads/\ncache/\n", info.contents)
end)

test("writes remote ignore rules through stdin", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local captured
  local runner = function(command, options)
    captured = { command = command, options = options }
    return { code = 0, stdout = "", stderr = "" }
  end
  require("remote-mirror.transport").new(config, runner):write_remote_ignore("uploads/\n")
  assert_equal("uploads/\n", captured.options.stdin)
  assert(captured.command[#captured.command]:find(".remoteignore.remote%-mirror.tmp"))
end)

test("parses an rsync dry-run estimate", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local runner = function()
    return {
      code = 0,
      stdout = table.concat({
        "Number of regular files transferred: 12,345",
        "Total file size: 124,780,544 bytes",
      }, "\n"),
      stderr = "",
    }
  end
  local estimate = require("remote-mirror.transport").new(config, runner):estimate("/tmp/filter")
  assert_equal(124780544, estimate.size)
  assert_equal(12345, estimate.files)
end)

test("estimates an SCP mirror from the manifest and ignore rules", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    transfer = "scp",
    default_ignore = { "vendor/" },
  })
  local runner = function()
    return {
      code = 0,
      stdout = table.concat({
        "10\t1.0\tmain.lua",
        "1000\t1.0\tvendor/library.lua",
        "20\t1.0\tdocs/readme.md",
      }, "\n"),
      stderr = "",
    }
  end
  local estimate = require("remote-mirror.transport").new(config, runner):estimate(nil, "")
  assert_equal(30, estimate.size)
  assert_equal(2, estimate.files)
end)

test("lists checksum differences for reconnect review", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "modified.lua"), "local\n")
  local captured
  local runner = function(command)
    captured = command
    return {
      code = 0,
      stdout = table.concat({
        ">fcst......\tmodified.lua",
        ">f+++++++++\tremote.lua",
        "*deleting  \tlocal.lua",
        "*deleting  \tempty/",
      }, "\n"),
      stderr = "",
    }
  end
  local changes = require("remote-mirror.transport").new(config, runner):changes("/tmp/filter")
  assert_contains(captured, "--dry-run")
  assert_contains(captured, "--checksum")
  assert_contains(captured, "--delete")
  assert_equal({
    {
      path = "local.lua",
      kind = "local_only",
      local_exists = true,
      remote_exists = false,
    },
    {
      path = "modified.lua",
      kind = "modified",
      local_exists = true,
      remote_exists = true,
    },
    {
      path = "remote.lua",
      kind = "remote_only",
      local_exists = false,
      remote_exists = true,
    },
  }, changes)
end)

test("builds a destructive force-push rsync command in the local-to-remote direction", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local captured
  local runner = function(command)
    captured = command
    return { code = 0, stdout = "", stderr = "" }
  end
  require("remote-mirror.transport").new(config, runner):push("/tmp/filter")
  assert_contains(captured, "--delete")
  assert_equal(config.source_root .. "/", captured[#captured - 1])
  assert_equal("server:/srv/example/", captured[#captured])
end)

test("runs child processes without blocking the Neovim event loop", function()
  local completed = false
  require("remote-mirror.async").run(function()
    local result = require("remote-mirror.async").runner({ "sh", "-c", "printf async" })
    return result.stdout
  end, function(ok, output)
    assert_equal(true, ok)
    assert_equal("async", output)
    completed = true
  end)
  assert_equal(false, completed)
  assert(vim.wait(1000, function()
    return completed
  end))
end)

test("serializes queued workspace operations", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local core = require("remote-mirror.core").new(config)
  local order = {}
  local completed = 0
  local function enqueue(label)
    core:enqueue(function()
      table.insert(order, "start-" .. label)
      require("remote-mirror.async").runner({ "sh", "-c", "printf " .. label })
      table.insert(order, "end-" .. label)
    end, function(ok)
      assert_equal(true, ok)
      completed = completed + 1
    end)
  end
  enqueue("one")
  enqueue("two")
  assert(vim.wait(1000, function()
    return completed == 2
  end))
  assert_equal({
    "start-one",
    "end-one",
    "start-two",
    "end-two",
  }, order)
end)

test("passes a workspace port to SSH and rsync", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    port = 65002,
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local commands = {}
  local runner = function(command)
    table.insert(commands, command)
    return { code = 0, stdout = "", stderr = "" }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  transport:ssh("true")
  transport:download("main.lua")
  assert_contains(commands[1], "ConnectTimeout=10")
  assert_contains(commands[1], "NumberOfPasswordPrompts=1")
  assert_contains(commands[1], "65002")
  assert_contains(commands[1], "server")
  assert_contains(commands[2], "--protect-args")
  assert(find_prefixed(commands[2], "--rsh="):find("-p 65002", 1, true))
end)

test("passes connection and executable overrides to SCP", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    user = "deploy",
    port = 65002,
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    transfer = "scp",
    ssh_command = "custom-ssh",
    ssh_args = { "-o", "Compression=yes" },
    scp_command = "custom-scp",
    scp_args = { "-O" },
  })
  local commands = {}
  local runner = function(command)
    table.insert(commands, command)
    return { code = 0, stdout = "", stderr = "" }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  transport:download("src/main.lua")
  assert_equal("custom-scp", commands[1][1])
  assert_contains(commands[1], "-P")
  assert_contains(commands[1], "65002")
  assert_contains(commands[1], "-O")
  assert_equal("deploy@server:/srv/example/src/main.lua", commands[1][#commands[1] - 1])
  transport:ssh("true")
  assert_equal("custom-ssh", commands[2][1])
  assert_contains(commands[2], "Compression=yes")
end)

test("SCP force pull transfers included files and preserves ignored paths", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    transfer = "scp",
    default_ignore = { "vendor/" },
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(util.join(config.source_root, "vendor"))
  util.write_file(util.join(config.source_root, "local-only.lua"), "remove\n")
  util.write_file(util.join(config.source_root, "vendor/local.lua"), "preserve\n")
  local transport = require("remote-mirror.transport").new(config, function()
    error("runner should not be used")
  end)
  transport.remote_ignore = function()
    return ""
  end
  transport.manifest = function()
    return {
      ["main.lua"] = { size = 4 },
      ["vendor/remote.lua"] = { size = 4 },
    }
  end
  local downloaded = {}
  transport.download = function(_, path)
    table.insert(downloaded, path)
  end
  transport:_scp_pull()
  assert_equal({ "main.lua" }, downloaded)
  assert_equal(false, util.is_file(util.join(config.source_root, "local-only.lua")))
  assert_equal(true, util.is_file(util.join(config.source_root, "vendor/local.lua")))
end)

test("SCP protected pull does not overwrite or delete local changes", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    transfer = "scp",
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "modified.lua"), "local\n")
  util.write_file(util.join(config.source_root, "local-only.lua"), "local\n")
  local transport = require("remote-mirror.transport").new(config, function()
    error("runner should not be used")
  end)
  transport.remote_ignore = function()
    return ""
  end
  transport.manifest = function()
    return {
      ["modified.lua"] = { size = 6 },
    }
  end
  local downloaded = {}
  transport.download = function(_, path)
    table.insert(downloaded, path)
  end
  transport:_scp_pull({ "modified.lua", "local-only.lua" })
  assert_equal({}, downloaded)
  assert_equal(true, util.is_file(util.join(config.source_root, "modified.lua")))
  assert_equal(true, util.is_file(util.join(config.source_root, "local-only.lua")))
end)

test("SCP force push transfers included files and protects ignored remote files", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    transfer = "scp",
    default_ignore = { "vendor/" },
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(util.join(config.source_root, "vendor"))
  util.write_file(util.join(config.source_root, "main.lua"), "push\n")
  util.write_file(util.join(config.source_root, "vendor/local.lua"), "ignore\n")
  local transport = require("remote-mirror.transport").new(config, function()
    error("runner should not be used")
  end)
  transport.remote_ignore = function()
    return ""
  end
  transport.manifest = function()
    return {
      ["remote-only.lua"] = { size = 4 },
      ["vendor/remote.lua"] = { size = 4 },
    }
  end
  local uploaded, deleted = {}, {}
  transport.upload = function(_, path)
    table.insert(uploaded, path)
  end
  transport.delete = function(_, path)
    table.insert(deleted, path)
  end
  transport:_scp_push()
  assert_equal({ "main.lua" }, uploaded)
  assert_equal({ "remote-only.lua" }, deleted)
end)

test("SCP review compares included files by hash", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    transfer = "scp",
    default_ignore = { "vendor/" },
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "same.lua"), "same\n")
  util.write_file(util.join(config.source_root, "modified.lua"), "local\n")
  util.write_file(util.join(config.source_root, "local-only.lua"), "local\n")
  local transport = require("remote-mirror.transport").new(config, function()
    error("runner should not be used")
  end)
  transport.remote_ignore = function()
    return ""
  end
  transport.manifest = function()
    return {
      ["same.lua"] = { size = 5 },
      ["modified.lua"] = { size = 7 },
      ["remote-only.lua"] = { size = 7 },
      ["vendor/ignored.lua"] = { size = 7 },
    }
  end
  transport.hash_manifest = function()
    return {
      ["same.lua"] = util.hash_file(util.join(config.source_root, "same.lua")),
      ["modified.lua"] = "remote-modified.lua",
      ["remote-only.lua"] = "remote-remote-only.lua",
      ["vendor/ignored.lua"] = "remote-vendor",
    }
  end
  local changes = transport:_scp_changes()
  assert_equal("local-only.lua", changes[1].path)
  assert_equal("local_only", changes[1].kind)
  assert_equal("modified.lua", changes[2].path)
  assert_equal("modified", changes[2].kind)
  assert_equal("remote-only.lua", changes[3].path)
  assert_equal("remote_only", changes[3].kind)
  assert_equal(3, #changes)
end)

test("does not override SSH config when user and port are unset", function()
  local config = require("remote-mirror.config").normalize({
    host = "server-alias",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local commands = {}
  local runner = function(command)
    table.insert(commands, command)
    return { code = 0, stdout = "", stderr = "" }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  transport:ssh("true")
  transport:download("main.lua")
  assert_contains(commands[1], "server-alias")
  assert(not vim.tbl_contains(commands[1], "-p"))
  assert(not find_prefixed(commands[2], "--rsh="):find(" -p ", 1, true))
end)

test("uses an explicit user and transient password without storing it in the helper", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    user = "deploy",
    port = 65002,
    auth = "password",
    _password = "not-persisted",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local captured
  local runner = function(command, options)
    captured = { command = command, options = options }
    return { code = 0, stdout = "", stderr = "" }
  end
  require("remote-mirror.transport").new(config, runner):ssh("true")
  assert_contains(captured.command, "65002")
  assert_contains(captured.command, "deploy")
  assert_contains(captured.command, "PreferredAuthentications=password,keyboard-interactive")
  assert_contains(captured.command, "PubkeyAuthentication=no")
  assert_equal("not-persisted", captured.options.env.REMOTE_MIRROR_PASSWORD)
  local helper = require("remote-mirror.util").read_file(config.state_root .. "/askpass.sh")
  assert(not helper:find("not%-persisted"))
end)

test("refuses a push after the remote changed", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    port = 65002,
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
    inspect = function()
      return {
        hash = "remote-changed",
        signature = "20:1700000000",
        size = 20,
        mtime = 1700000000,
      }
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

test("refuses a reviewed push when the remote changed after comparison", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "main.lua"), "local choice\n")
  local uploaded = false
  local transport = {
    inspect = function()
      return { hash = "changed-after-review" }
    end,
    upload = function()
      uploaded = true
    end,
  }
  local core = require("remote-mirror.core").new(config, { transport = transport })
  local result = core:apply_reconcile({
    {
      path = "main.lua",
      local_exists = true,
      remote_exists = true,
      local_hash = "local-at-review",
      remote_hash = "remote-at-review",
    },
  }, { ["main.lua"] = "push" })
  assert_equal(0, result.applied)
  assert_equal(1, result.conflicts)
  assert_equal(false, uploaded)
end)

test("allows a later safe upload for a reviewed local-only file", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "new.lua"), "new\n")
  local State = require("remote-mirror.state")
  local state = State.new(config)
  state.data.files["new.lua"] = {
    remote_hash = vim.NIL,
    local_hash = "previous-local",
    materialized = true,
  }
  local uploaded = false
  local transport = {
    inspect = function()
      if uploaded then
        return { hash = util.hash_file(util.join(config.source_root, "new.lua")) }
      end
      return nil
    end,
    upload = function()
      uploaded = true
    end,
  }
  local core = require("remote-mirror.core").new(config, {
    state = state,
    transport = transport,
  })
  assert_equal(true, core:push_file("new.lua", false))
  assert_equal(true, uploaded)
end)

test("building a reconnect review does not advance synchronization state", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local State = require("remote-mirror.state")
  local state = State.new(config)
  state.data.files["main.lua"] = {
    remote_hash = "baseline",
    remote_signature = "8:1",
    local_hash = "local-baseline",
    materialized = true,
  }
  local transport = {
    manifest = function()
      return {
        ["main.lua"] = { signature = "9:2", size = 9, mtime = 2 },
      }
    end,
    remote_ignore = function()
      return ""
    end,
    changes = function()
      return {
        {
          path = "main.lua",
          kind = "modified",
          local_exists = true,
          remote_exists = true,
        },
      }
    end,
    inspect = function()
      return { hash = "reviewed-remote" }
    end,
  }
  local core = require("remote-mirror.core").new(config, {
    state = state,
    transport = transport,
  })
  core:reconcile_plan()
  assert_equal("baseline", state.data.files["main.lua"].remote_hash)
  assert_equal("8:1", state.data.files["main.lua"].remote_signature)
end)

test("force pull replaces the mirror and resets its synchronization state", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  util.write_file(util.join(config.source_root, "local-only.lua"), "stale\n")
  local transport = {
    manifest = function()
      return {
        ["remote.lua"] = {
          signature = "7:1700000000",
          size = 7,
          mtime = 1700000000,
        },
      }
    end,
    remote_ignore = function()
      return ""
    end,
    pull = function()
      os.remove(util.join(config.source_root, "local-only.lua"))
      util.write_file(util.join(config.source_root, "remote.lua"), "remote\n")
    end,
  }
  local core = require("remote-mirror.core").new(config, { transport = transport })
  core.state:add_conflict("old.lua", "both_modified", "local", "remote", "base")
  core:force_pull()
  assert_equal(false, util.is_file(util.join(config.source_root, "local-only.lua")))
  assert_equal(true, util.is_file(util.join(config.source_root, "remote.lua")))
  assert_equal(true, core.state.data.files["remote.lua"].materialized)
  assert_equal({}, core.state.data.conflicts)
end)

test("persists named workspaces", function()
  local path = vim.fn.tempname() .. "/workspaces.json"
  local registry = require("remote-mirror.registry").new(path)
  registry:add({
    name = "website",
    host = "server",
    user = "deploy",
    port = 65002,
    auth = "password",
    transfer = "scp",
    scp_command = "/opt/bin/scp",
    scp_args = { "-O" },
    _password = "must-not-be-saved",
    remote_root = "/srv/website",
    mirror_root = "/tmp/website",
    source_root = "/tmp/website/source",
  })
  local loaded = require("remote-mirror.registry").new(path):load()
  assert_equal("server", loaded.workspaces.website.host)
  assert_equal("deploy", loaded.workspaces.website.user)
  assert_equal(65002, loaded.workspaces.website.port)
  assert_equal("password", loaded.workspaces.website.auth)
  assert_equal("scp", loaded.workspaces.website.transfer)
  assert_equal("/opt/bin/scp", loaded.workspaces.website.scp_command)
  assert_equal({ "-O" }, loaded.workspaces.website.scp_args)
  assert(not require("remote-mirror.util").read_file(path):find("must%-not%-be%-saved"))
  assert_equal("/srv/website", loaded.workspaces.website.remote_root)
end)

test("can clear explicit workspace connection overrides", function()
  local registry_path = vim.fn.tempname() .. "/workspaces.json"
  local manager = require("remote-mirror.manager").new({ registry_path = registry_path })
  manager:add({
    name = "website",
    host = "server",
    user = "deploy",
    port = 65002,
    auth = "password",
    remote_root = "/srv/website",
  })
  manager:update_connection("website", {
    user = nil,
    port = nil,
    auth = "ssh",
  })
  assert_equal(nil, manager.registry.workspaces.website.user)
  assert_equal(nil, manager.registry.workspaces.website.port)
  assert_equal("ssh", manager.registry.workspaces.website.auth)
end)

test("deletes a workspace registration without touching its mirror", function()
  local registry_path = vim.fn.tempname() .. "/workspaces.json"
  local mirror_root = vim.fn.tempname()
  local util = require("remote-mirror.util")
  util.ensure_dir(mirror_root)
  util.write_file(util.join(mirror_root, "kept.txt"), "keep\n")
  local manager = require("remote-mirror.manager").new({ registry_path = registry_path })
  manager:add({
    name = "website",
    host = "server",
    remote_root = "/srv/website",
    mirror_root = mirror_root,
  })
  manager:set_password("website", "transient")
  manager:remove("website")
  assert_equal(nil, manager.registry.workspaces.website)
  assert_equal(false, manager:has_password("website"))
  assert_equal(true, util.is_file(util.join(mirror_root, "kept.txt")))
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
          signature = "7:1700000000",
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
