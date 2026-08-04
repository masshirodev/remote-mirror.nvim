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

test("normalizes remote sudo for rsync workspaces", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    remote_sudo = true,
    mirror_root = "/tmp/remote-mirror-test",
  })
  assert_equal(true, config.remote_sudo)
  assert_equal("passwordless", config.remote_sudo_auth)

  local password_config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    remote_sudo = true,
    remote_sudo_auth = "password",
    mirror_root = "/tmp/remote-mirror-test",
  })
  assert_equal("password", password_config.remote_sudo_auth)

  local scp_ok, scp_err = pcall(require("remote-mirror.config").normalize, {
    host = "server",
    remote_root = "/srv/example",
    transfer = "scp",
    remote_sudo = true,
    mirror_root = "/tmp/remote-mirror-test",
  })
  assert_equal(false, scp_ok)
  assert(scp_err:find("requires transfer = rsync", 1, true), scp_err)
end)

test("reports the rejected value when a user is unusable", function()
  local ok, err = pcall(require("remote-mirror.config").normalize, {
    host = "server",
    user = "u914019733@server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  assert_equal(false, ok)
  assert(err:find('"u914019733@server"', 1, true), err)

  local trailing_ok, trailing_err = pcall(require("remote-mirror.config").normalize, {
    host = "server",
    user = "u914019733 ",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  assert_equal(false, trailing_ok)
  assert(trailing_err:find('"u914019733 "', 1, true), trailing_err)
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
      signature = "42:1700000000",
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
  local transport = require("remote-mirror.transport").new(config, runner)
  local manifest = transport:manifest()
  assert_equal(12, manifest["src/main.lua"].size)
  assert(manifest["src/main.lua"].signature:match("^12:%d+$"))
  -- A pushed file records the signature `inspect` saw while a refresh records
  -- the one `manifest` saw, so the two commands must agree about the same file.
  assert_equal(manifest["src/main.lua"].signature, transport:inspect("src/main.lua").signature)
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
      stdout = table.concat({
        "35369",
        "104857600\t./storage/logs",
        "209715200\t./storage",
        "52428800\t./node_modules",
        "1610612736\t.",
      }, "\n") .. "\n",
      stderr = "",
    }
  end
  local stats = require("remote-mirror.transport").new(config, runner):workspace_stats()
  assert_equal(1610612736, stats.size)
  assert_equal(35369, stats.files)
  assert_equal({
    { path = "storage", size = 209715200 },
    { path = "storage/logs", size = 104857600 },
    { path = "node_modules", size = 52428800 },
  }, stats.directories)
end)

test("suggests heavy directories that the current rules still mirror", function()
  local Ignore = require("remote-mirror.ignore")
  local directories = {
    { path = "node_modules", size = 400 * 1024 * 1024 },
    { path = "storage", size = 300 * 1024 * 1024 },
    { path = "storage/logs", size = 290 * 1024 * 1024 },
    { path = "public/uploads", size = 40 * 1024 * 1024 },
    { path = "src", size = 2 * 1024 * 1024 },
  }
  local suggestions = Ignore.suggest(directories, { "node_modules/", "*.log" }, "")
  assert_equal({
    { path = "storage/logs", size = 290 * 1024 * 1024 },
    { path = "public/uploads", size = 40 * 1024 * 1024 },
  }, suggestions)

  local with_remote = Ignore.suggest(directories, { "node_modules/" }, "storage/\n")
  assert_equal({ { path = "public/uploads", size = 40 * 1024 * 1024 } }, with_remote)
  assert_equal({}, Ignore.suggest(nil, {}, ""))
end)

test("lists a remote directory with folders before files", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local captured
  local runner = function(command)
    captured = command[#command]
    return {
      code = 0,
      stdout = table.concat({
        "/srv/apps",
        "f\tREADME.md",
        "d\twebsite",
        "f\t.env",
        "d\t.config",
      }, "\n") .. "\n",
      stderr = "",
    }
  end
  local listing = require("remote-mirror.transport").new(config, runner):list_directory("/srv/apps/")
  assert(captured:find("cd '/srv/apps/'", 1, true))
  assert_equal("/srv/apps", listing.path)
  assert_equal({
    { name = ".config", kind = "directory" },
    { name = "website", kind = "directory" },
    { name = ".env", kind = "file" },
    { name = "README.md", kind = "file" },
  }, listing.entries)
end)

test("lists the remote home directory when no path is given", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local captured
  local runner = function(command)
    captured = command[#command]
    return { code = 0, stdout = "/home/deploy\n", stderr = "" }
  end
  local listing = require("remote-mirror.transport").new(config, runner):list_directory(nil)
  assert(captured:find('cd "$HOME"', 1, true))
  assert_equal("/home/deploy", listing.path)
  assert_equal({}, listing.entries)
end)

test("rejects an unreadable remote directory listing", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local runner = function()
    return { code = 0, stdout = "", stderr = "" }
  end
  local ok = pcall(function()
    require("remote-mirror.transport").new(config, runner):list_directory("/srv")
  end)
  assert_equal(false, ok)
end)

test("browses a remote host before a project root is chosen", function()
  local script = vim.fn.tempname()
  local file = assert(io.open(script, "w"))
  file:write("#!/bin/sh\nprintf '/srv\\nd\\twebsite\\nf\\tnotes.txt\\n'\n")
  file:close()
  assert(vim.uv.fs_chmod(script, 493))

  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
    mirror_root = vim.fn.tempname(),
    ssh_command = script,
  })
  local completed, listing
  manager:browse_remote_async({ name = "website", host = "server" }, nil, "/srv", function(ok, result)
    assert_equal(true, ok)
    listing = result
    completed = true
  end)
  assert(vim.wait(2000, function()
    return completed
  end))
  assert_equal("/srv", listing.path)
  assert_equal({
    { name = "website", kind = "directory" },
    { name = "notes.txt", kind = "file" },
  }, listing.entries)
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

test("uses noninteractive sudo for remote shell and rsync writes", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    remote_sudo = true,
    mirror_root = vim.fn.tempname(),
  })
  local commands = {}
  local runner = function(command)
    table.insert(commands, command)
    return { code = 0, stdout = "", stderr = "" }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  transport:ssh("mkdir -p /srv/example")
  transport:upload("main.lua")
  assert(commands[1][#commands[1]]:find("sudo %-n sh %-c", 1, false), commands[1][#commands[1]])
  local rsync_path
  for _, command in ipairs(commands) do
    rsync_path = find_prefixed(command, "--rsync-path=")
    if rsync_path then
      break
    end
  end
  assert(rsync_path and rsync_path:find("sudo %-n", 1, false), vim.inspect(commands))
end)

test("uses a transient sudo password for shell commands and rsync authentication", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    remote_sudo = true,
    remote_sudo_auth = "password",
    mirror_root = vim.fn.tempname(),
    _sudo_password = "sudo-secret",
  })
  local commands = {}
  local runner = function(command, options)
    table.insert(commands, { command = command, options = options })
    return { code = 0, stdout = "", stderr = "" }
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  transport:ssh("mkdir -p /srv/example")
  transport:upload("main.lua")

  assert(commands[1].command[#commands[1].command]:find("sudo %-S %-p '' sh %-c", 1, false))
  assert_equal("sudo-secret\n", commands[1].options.stdin)
  assert(commands[3].command[#commands[3].command]:find("sudo -S -p '' -v", 1, true))
  assert_equal("sudo-secret\n", commands[3].options.stdin)
  assert(commands[4].command[1] == "rsync")
  assert(not vim.inspect(commands[4].command):find("sudo%-secret", 1, false))
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

test("reports a mirror that was built for another endpoint", function()
  local mirror_root = vim.fn.tempname()
  local function workspace(host, remote_root, user)
    return require("remote-mirror.config").normalize({
      name = "website",
      host = host,
      user = user,
      remote_root = remote_root,
      mirror_root = mirror_root,
    })
  end

  local first = workspace("server-a", "/srv/site")
  local core = require("remote-mirror.core").new(first)
  core:ensure_layout()
  core.state:save()

  local reconnected = require("remote-mirror.state").new(workspace("server-a", "/srv/site", "deploy")):load()
  assert_equal(nil, reconnected.foreign)

  local moved_host = require("remote-mirror.state").new(workspace("server-b", "/srv/site")):load()
  assert_equal({ host = "server-a", remote_root = "/srv/site" }, moved_host.foreign)

  local moved_path = require("remote-mirror.state").new(workspace("server-a", "/var/www")):load()
  assert_equal({ host = "server-a", remote_root = "/srv/site" }, moved_path.foreign)
end)

test("adopts a mirror written before endpoints were recorded", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.write_file(
    util.join(config.state_root, "state.json"),
    vim.json.encode({ version = 1, files = {}, conflicts = {} })
  )
  local state = require("remote-mirror.state").new(config):load()
  assert_equal(nil, state.foreign)
end)

test("refuses to connect a workspace whose name was reused for another host", function()
  local mirror_root = vim.fn.tempname()
  local first = require("remote-mirror.config").normalize({
    name = "website",
    host = "server-a",
    remote_root = "/srv/site",
    mirror_root = mirror_root,
  })
  local core = require("remote-mirror.core").new(first)
  core:ensure_layout()
  core.state:save()

  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
    workspaces = {
      {
        name = "website",
        host = "server-b",
        remote_root = "/var/www",
        mirror_root = mirror_root,
      },
    },
  })

  local conflict = manager:mirror_conflict("website")
  assert_equal("server-a", conflict.host)
  assert_equal("/srv/site", conflict.remote_root)

  local failed, message = nil, nil
  manager:connect_async("website", "force_push", function(ok, result)
    failed = not ok
    message = result
  end)
  assert_equal(true, failed)
  assert(message:find(mirror_root, 1, true), message)
  assert(message:find("server-a:/srv/site", 1, true), message)
  assert_equal(nil, manager.current)
end)

test("resetting a mirror clears its files and frees a reused name", function()
  local mirror_root = vim.fn.tempname()
  local first = require("remote-mirror.config").normalize({
    name = "website",
    host = "server-a",
    remote_root = "/srv/site",
    mirror_root = mirror_root,
  })
  local core = require("remote-mirror.core").new(first)
  core:ensure_layout()
  core.state:save()
  require("remote-mirror.util").write_file(first.source_root .. "/index.html", "old\n")

  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
    workspaces = {
      {
        name = "website",
        host = "server-b",
        remote_root = "/var/www",
        mirror_root = mirror_root,
      },
    },
  })
  assert(manager:mirror_conflict("website"))
  assert_equal(true, manager:has_local_mirror("website"))

  local result = manager:reset_mirror("website")
  assert_equal(true, result.existed)
  assert_equal(0, vim.fn.isdirectory(mirror_root))
  assert_equal(nil, manager:mirror_conflict("website"))
  assert_equal(false, manager:has_local_mirror("website"))
  assert(manager:get("website"), "the registration must survive a reset")

  local repeated = manager:reset_mirror("website")
  assert_equal(false, repeated.existed)
end)

test("refuses to reset a connected or externally rooted mirror", function()
  local mirror_root = vim.fn.tempname()
  local outside_source = vim.fn.tempname()
  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
    workspaces = {
      { name = "website", host = "server", remote_root = "/srv/site", mirror_root = mirror_root },
      {
        name = "external",
        host = "server",
        remote_root = "/srv/other",
        mirror_root = vim.fn.tempname(),
        source_root = outside_source,
      },
    },
  })

  local config = manager:workspace_options(manager:get("website"))
  local core = require("remote-mirror.core").new(config)
  core:ensure_layout()
  manager:_activate(core)
  local connected_ok, connected_err = pcall(manager.reset_mirror, manager, "website")
  assert_equal(false, connected_ok)
  assert(connected_err:find("disconnect", 1, true), connected_err)
  manager:disconnect()
  assert_equal(1, vim.fn.isdirectory(mirror_root))

  require("remote-mirror.util").ensure_dir(outside_source)
  local external_ok, external_err = pcall(manager.reset_mirror, manager, "external")
  assert_equal(false, external_ok)
  assert(external_err:find("source_root is outside", 1, true), external_err)
  assert_equal(1, vim.fn.isdirectory(outside_source))

  local unknown_ok = pcall(manager.reset_mirror, manager, "missing")
  assert_equal(false, unknown_ok)
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

test("disconnecting stops watching and restores the previous directory", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local core = require("remote-mirror.core").new(config)
  core:ensure_layout()
  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
  })

  local previous = vim.fn.getcwd()
  manager:_activate(core)
  assert_equal("source", vim.fn.fnamemodify(vim.fn.getcwd(), ":t"))
  assert(core.watcher)

  local result = manager:disconnect()
  assert_equal("example", result.name)
  assert_equal(0, result.pending)
  assert_equal(nil, manager.current)
  assert_equal(nil, core.watcher)
  assert_equal(true, core.detached)
  assert_equal(previous, vim.fn.getcwd())
end)

test("refuses to disconnect while an operation is running", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    watch = false,
  })
  local core = require("remote-mirror.core").new(config)
  core:ensure_layout()
  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
  })
  manager:_activate(core)

  local finished, queued_error = false, nil
  core:enqueue(function()
    require("remote-mirror.async").runner({ "sh", "-c", "sleep 0.2" })
  end, function()
    finished = true
  end)
  core:enqueue(function()
    error("remote-mirror: this queued operation must never run")
  end, function(ok, err)
    queued_error = not ok and err or nil
  end)

  local refused, message = pcall(manager.disconnect, manager)
  assert_equal(false, refused)
  assert(message:find("RemoteMirrorDisconnect!", 1, true), message)
  assert_equal(core, manager.current)

  local result = manager:disconnect(true)
  assert_equal("example", result.name)
  assert_equal(nil, manager.current)
  assert_equal("remote-mirror: the workspace was disconnected", queued_error)
  assert(vim.wait(1000, function()
    return finished
  end))
end)

test("a forced disconnect drops uploads that were waiting to run", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    watch = false,
    debounce_ms = 50,
  })
  local uploaded = {}
  local core = require("remote-mirror.core").new(config, {
    transport = {
      inspect = function()
        return nil
      end,
      upload = function(_, path)
        table.insert(uploaded, path)
      end,
      delete = function() end,
    },
  })
  core:ensure_layout()
  require("remote-mirror.util").write_file(config.source_root .. "/notes.txt", "local edit\n")

  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
  })
  manager:_activate(core)
  core:schedule_upload("notes.txt")
  assert_equal(1, vim.tbl_count(core.pending))

  local refused, message = pcall(manager.disconnect, manager)
  assert_equal(false, refused)
  assert(message:find("waiting to upload", 1, true), message)

  local result = manager:disconnect(true)
  assert_equal(1, result.pending)
  assert_equal({}, core.pending)

  vim.wait(300)
  assert_equal({}, uploaded)

  core:schedule_upload("notes.txt")
  vim.wait(200)
  assert_equal({}, uploaded)
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

test("signatures ignore the fraction that only find reports", function()
  local util = require("remote-mirror.util")
  assert_equal("12:1700000000", util.signature("12", "1700000000.0000000000"))
  assert_equal("12:1700000000", util.signature(12, 1700000000))
  assert_equal("12:1700000000", util.signature("12", "1700000000.9999999999"))
end)

test("reports remote observations as file status", function()
  local State = require("remote-mirror.state")
  assert_equal("clean", State.file_status({
    materialized = true,
    remote_signature = "4:1",
    observed_remote_signature = "4:1",
  }))
  assert_equal("remote_changed", State.file_status({
    materialized = true,
    remote_signature = "4:1",
    observed_remote_signature = "9:2",
  }))
  assert_equal("remote_deleted", State.file_status({
    materialized = true,
    remote_signature = "4:1",
    observed_remote_signature = vim.NIL,
  }))
  assert_equal("absent", State.file_status({
    materialized = false,
    remote_signature = "4:1",
    observed_remote_signature = "4:1",
  }))
  assert_equal("conflict", State.file_status({
    materialized = true,
    remote_signature = "4:1",
    observed_remote_signature = "4:1",
  }, { kind = "remote_modified" }))
end)

test("adopts entries recorded before observations existed", function()
  local State = require("remote-mirror.state")
  assert_equal("clean", State.file_status({ materialized = true, remote_signature = "4:1" }))
end)

test("reloads unmodified mirror buffers and reports modified ones", function()
  local util = require("remote-mirror.util")
  local root = vim.fn.tempname()
  util.ensure_dir(root)
  util.write_file(util.join(root, "clean.txt"), "before\n")
  util.write_file(util.join(root, "dirty.txt"), "before\n")
  util.write_file(util.join(root, "untouched.txt"), "before\n")

  for _, name in ipairs({ "clean.txt", "dirty.txt", "untouched.txt" }) do
    vim.cmd.edit(vim.fn.fnameescape(util.join(root, name)))
  end
  vim.cmd.edit(vim.fn.fnameescape(util.join(root, "dirty.txt")))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved" })

  util.write_file(util.join(root, "clean.txt"), "after\n")
  util.write_file(util.join(root, "dirty.txt"), "after\n")
  util.write_file(util.join(root, "untouched.txt"), "after\n")

  local stale = util.reload_buffers(root, { "clean.txt", "dirty.txt" })
  assert_equal({ "dirty.txt" }, stale)

  local function buffer_lines(name)
    local buffer = vim.fn.bufnr(util.join(root, name))
    return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  end
  assert_equal({ "after" }, buffer_lines("clean.txt"))
  assert_equal({ "unsaved" }, buffer_lines("dirty.txt"))
  -- Paths outside the requested set keep whatever the buffer already held.
  assert_equal({ "before" }, buffer_lines("untouched.txt"))

  for _, name in ipairs({ "clean.txt", "dirty.txt", "untouched.txt" }) do
    vim.cmd(("bwipeout! %d"):format(vim.fn.bufnr(util.join(root, name))))
  end
end)

test("reloads buffers rewritten by a pull", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  local absolute = util.join(config.source_root, "main.lua")
  util.write_file(absolute, "before\n")
  vim.cmd.edit(vim.fn.fnameescape(absolute))
  local buffer = vim.fn.bufnr(absolute)

  local transport = {
    manifest = function()
      return { ["main.lua"] = { signature = "6:1700000000", size = 6, mtime = 1700000000 } }
    end,
    remote_ignore = function()
      return ""
    end,
    pull = function()
      util.write_file(absolute, "after\n")
    end,
    inspect = function()
      return nil
    end,
  }
  local core = require("remote-mirror.core").new(config, { transport = transport })
  core.state.data.files["main.lua"] = {
    remote_hash = util.hash_file(absolute),
    remote_signature = "6:1700000000",
    observed_remote_signature = "6:1700000000",
    local_hash = util.hash_file(absolute),
    materialized = true,
  }
  core:pull()

  assert_equal({ "after" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))
  vim.cmd(("bwipeout! %d"):format(buffer))
end)

test("polls open paths with one stat call", function()
  local root = vim.fn.tempname() .. " with quote's"
  local util = require("remote-mirror.util")
  util.ensure_dir(util.join(root, "src"))
  util.write_file(util.join(root, "src/main.lua"), "return true\n")
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = root,
    mirror_root = vim.fn.tempname(),
  })
  local calls = 0
  local runner = function(command)
    calls = calls + 1
    return vim.system({ "sh", "-c", command[#command] }, { text = true }):wait()
  end
  local transport = require("remote-mirror.transport").new(config, runner)
  local signatures = transport:signatures({ "src/main.lua", "gone.lua" })

  assert_equal(1, calls)
  assert_equal(transport:manifest()["src/main.lua"].signature, signatures["src/main.lua"])
  assert_equal(nil, signatures["gone.lua"])
  assert_equal({}, require("remote-mirror.transport").new(config, function()
    error("runner should not be used")
  end):signatures({}))
end)

local function poll_fixture(options)
  local config = require("remote-mirror.config").normalize(vim.tbl_extend("force", {
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  }, options or {}))
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  local absolute = util.join(config.source_root, "main.lua")
  util.write_file(absolute, "before\n")

  local downloaded = {}
  local transport = {
    signatures = function()
      return { ["main.lua"] = "5:1700000009" }
    end,
    inspect = function()
      return { hash = "remote-hash", signature = "5:1700000009", size = 5, mtime = 1700000009 }
    end,
    download = function(_, path)
      table.insert(downloaded, path)
      util.write_file(absolute, "after\n")
    end,
  }
  local core = require("remote-mirror.core").new(config, { transport = transport })
  core.state.data.files["main.lua"] = {
    remote_hash = "base-hash",
    remote_signature = "6:1700000000",
    observed_remote_signature = "6:1700000000",
    local_hash = util.hash_file(absolute),
    materialized = true,
  }
  return core, absolute, downloaded
end

test("a poll pulls a remotely changed file whose local copy is untouched", function()
  local core, absolute, downloaded = poll_fixture()
  local result = core:poll({ { path = "main.lua", modified = false } })

  assert_equal({ "main.lua" }, downloaded)
  assert_equal({ "main.lua" }, result.pulled)
  assert_equal({}, result.conflicts)
  assert_equal("after\n", require("remote-mirror.util").read_file(absolute))
  assert_equal("5:1700000009", core.state.data.files["main.lua"].remote_signature)
  assert_equal(nil, core.state.data.conflicts["main.lua"])
end)

test("a poll leaves a locally changed file alone and records the conflict", function()
  local core, absolute, downloaded = poll_fixture()
  require("remote-mirror.util").write_file(absolute, "local edit\n")
  local result = core:poll({ { path = "main.lua", modified = false } })

  assert_equal({}, downloaded)
  assert_equal({ "main.lua" }, result.conflicts)
  assert_equal("local edit\n", require("remote-mirror.util").read_file(absolute))
  assert_equal("remote_modified", core.state.data.conflicts["main.lua"].kind)
  -- The baseline must not advance, so the file stays marked until it is resolved.
  assert_equal("6:1700000000", core.state.data.files["main.lua"].remote_signature)
  assert_equal("remote_changed", require("remote-mirror.state").file_status(
    core.state.data.files["main.lua"]
  ))
end)

test("a poll never overwrites a file whose buffer has unsaved changes", function()
  local core, _, downloaded = poll_fixture()
  local result = core:poll({ { path = "main.lua", modified = true } })

  assert_equal({}, downloaded)
  assert_equal({ "main.lua" }, result.conflicts)
end)

test("a poll reports a remotely changed file when auto pull is disabled", function()
  local core, absolute, downloaded = poll_fixture({ poll_auto_pull = false })
  local result = core:poll({ { path = "main.lua", modified = false } })

  assert_equal({}, downloaded)
  assert_equal({ "main.lua" }, result.changed)
  assert_equal({}, result.conflicts)
  assert_equal("before\n", require("remote-mirror.util").read_file(absolute))
end)

test("a poll reports a remote deletion without deleting the local file", function()
  local core, absolute, downloaded = poll_fixture()
  core.transport.signatures = function()
    return {}
  end
  local result = core:poll({ { path = "main.lua", modified = false } })

  assert_equal({}, downloaded)
  assert_equal({ "main.lua" }, result.removed)
  assert_equal(true, require("remote-mirror.util").is_file(absolute))
  assert_equal("remote_deleted", require("remote-mirror.state").file_status(
    core.state.data.files["main.lua"]
  ))
end)

test("only loaded workspace files are polled", function()
  local core, absolute = poll_fixture()
  local util = require("remote-mirror.util")
  util.write_file(util.join(core.config.source_root, "untracked.lua"), "x\n")

  assert_equal({}, core:open_paths())
  vim.cmd.edit(vim.fn.fnameescape(absolute))
  vim.cmd.edit(vim.fn.fnameescape(util.join(core.config.source_root, "untracked.lua")))
  -- The untracked file has no manifest entry, so there is nothing to compare.
  assert_equal({ { path = "main.lua", modified = false } }, core:open_paths())

  for _, name in ipairs({ "main.lua", "untracked.lua" }) do
    vim.cmd(("bwipeout! %d"):format(vim.fn.bufnr(util.join(core.config.source_root, name))))
  end
end)

test("a detached workspace stops polling", function()
  local core = poll_fixture({ poll_interval_ms = 1000 })
  core:start_poll_timer()
  assert(core.poll_timer)
  core:detach()
  assert_equal(nil, core.poll_timer)
  assert_equal(false, (core:schedule_poll()))
end)

local function buffers_named(name)
  local found = 0
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buffer) == name then
      found = found + 1
    end
  end
  return found
end

test("reopening the workspace list replaces the buffer holding its name", function()
  local manager = {
    current = nil,
    list = function()
      return {}
    end,
  }
  local ui = require("remote-mirror.ui")
  ui.open(manager)
  local first = vim.api.nvim_get_current_buf()
  -- A scratch buffer keeps its name until it is wiped, so a second screen used
  -- to fail with E95 instead of replacing the first.
  ui.open(manager)
  local second = vim.api.nvim_get_current_buf()

  assert(first ~= second, "expected a new buffer")
  assert_equal(false, vim.api.nvim_buf_is_valid(first))
  assert_equal(1, buffers_named("remote-mirror://workspaces"))
  vim.cmd("bwipeout!")
end)

test("reopening a workspace screen replaces the buffer holding its name", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    name = "website",
  })
  local core = {
    config = config,
    state = { data = { files = {}, conflicts = {} } },
    enqueue = function() end,
  }
  local ui = require("remote-mirror.ui")
  ui.open_workspace({}, core)
  local first = vim.api.nvim_get_current_buf()
  ui.open_workspace({}, core)

  assert(first ~= vim.api.nvim_get_current_buf(), "expected a new buffer")
  assert_equal(false, vim.api.nvim_buf_is_valid(first))
  assert_equal(1, buffers_named("remote-mirror://workspace/website"))
  vim.cmd("bwipeout!")
end)

local function ignore_editor_fixture(existing)
  local written = {}
  local manager = {
    current = nil,
    credentials = { website = nil },
    list = function()
      return {}
    end,
    workspace_options = function(_, workspace)
      return require("remote-mirror.config").normalize(
        vim.tbl_extend("force", { mirror_root = vim.fn.tempname() }, workspace)
      )
    end,
    remote_ignore_at_async = function(_, _, _, path, callback)
      callback(true, {
        exists = existing ~= nil,
        contents = existing or "",
        path = path,
      })
    end,
    write_remote_ignore_at_async = function(_, _, _, path, contents, callback)
      written.path = path
      written.contents = contents
      callback(true)
    end,
  }
  return manager, written
end

local function save_editor()
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)
end

test("editing a registered workspace's rules writes them without guidance", function()
  local manager, written = ignore_editor_fixture(nil)
  local closed = false
  require("remote-mirror.ui")._edit_workspace_ignore(
    manager,
    { name = "website", host = "server", remote_root = "/srv/website" },
    function()
      closed = true
    end
  )

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  -- Guidance is visible while editing but must never reach the file.
  assert_equal(true, lines[1]:find("remote-mirror:", 1, true) ~= nil)
  assert_contains(lines, "node_modules/")

  save_editor()
  assert_equal("/srv/website", written.path)
  assert_equal(true, closed)
  for _, line in ipairs(vim.split(written.contents, "\n", { plain = true })) do
    assert(
      line:sub(1, #"# remote-mirror:") ~= "# remote-mirror:",
      "guidance leaked into the file: " .. line
    )
  end
  assert_contains(vim.split(written.contents, "\n", { plain = true }), "node_modules/")
  vim.cmd("bwipeout!")
end)

test("editing existing rules round-trips their own comments", function()
  local existing = "# my own note\nstorage/\n!storage/keep.txt\n"
  local manager, written = ignore_editor_fixture(existing)
  require("remote-mirror.ui")._edit_workspace_ignore(
    manager,
    { name = "website", host = "server", remote_root = "/srv/website" },
    function() end
  )

  save_editor()
  -- A second round trip must produce the same file, not a growing header.
  assert_equal(existing, written.contents)
  vim.cmd("bwipeout!")
end)

test("rules drafted while browsing are not written to the directory on screen", function()
  local manager, written = ignore_editor_fixture(nil)
  manager.browse_remote_async = function(_, _, _, path, callback)
    callback(true, { path = path or "/home/deploy", entries = {} })
  end

  local rules = {}
  local selected
  local ui = require("remote-mirror.ui")
  ui._open_remote_browser(manager, { name = "website", host = "server" }, nil, function(root)
    selected = root
  end, function() end, rules, "/home/deploy/other")

  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  end

  feed("e")
  vim.api.nvim_buf_set_lines(0, -1, -1, false, { "storage/" })
  save_editor()

  -- Browsing must not touch the remote; the draft is held until a root is
  -- chosen, and then it belongs to that root rather than to this directory.
  assert_equal(nil, written.path)
  assert_contains(vim.split(rules.contents, "\n", { plain = true }), "storage/")

  feed(".")
  assert_equal("/home/deploy/other", selected)
  vim.cmd("bwipeout!")
end)

test("a draft outlives navigation and reseeds the editor", function()
  local manager = ignore_editor_fixture("from the remote\n")
  manager.browse_remote_async = function(_, _, _, path, callback)
    callback(true, { path = path or "/home/deploy", entries = {} })
  end

  local rules = { contents = "drafted/\n" }
  require("remote-mirror.ui")._open_remote_browser(
    manager,
    { name = "website", host = "server" },
    nil,
    function() end,
    function() end,
    rules,
    "/home/deploy"
  )
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("e", true, false, true), "x", false)

  -- Unwritten edits win over whatever the directory being browsed holds.
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert_contains(lines, "drafted/")
  for _, line in ipairs(lines) do
    assert(line ~= "from the remote", "the draft was replaced by the remote file")
  end
  vim.cmd("bwipeout!")
end)

test("workspace hooks wrap remote commands and preserve hook input", function()
  local mirror_root = vim.fn.tempname()
  local config = require("remote-mirror.config").normalize({
    name = "website",
    host = "server",
    remote_root = "/srv/website",
    mirror_root = mirror_root,
  })
  require("remote-mirror.util").ensure_dir(mirror_root)
  require("remote-mirror.util").write_file(
    config.mirror_root .. "/onRemoteCommand",
    "exec su -s /bin/sh -c \"$1\" chatwoo001\n"
  )
  config._hook_password = "secret"

  local commands, options = {}, nil
  local transport = require("remote-mirror.transport").new(config, function(command, process_options)
    commands[#commands + 1] = command
    options = process_options
    return { code = 0, stdout = "", stderr = "" }
  end)
  transport:ssh("printf ready", { stdin = "payload" })

  assert(commands[1][#commands[1]]:find("onRemoteCommand", 1, true) == nil)
  assert(commands[1][#commands[1]]:find("su %-s /bin/sh %-c", 1, false))
  assert(commands[1][#commands[1]]:find("chatwoo001", 1, true))
  assert_equal("secret\npayload", options.stdin)
  assert_equal("secret", options.env.REMOTE_MIRROR_HOOK_PASSWORD)

  local shell = transport:rsync_shell()
  assert(shell:find("remote%-command%-hook%.sh", 1, false))
  local wrapper = require("remote-mirror.util").read_file(config.state_root .. "/remote-command-hook.sh")
  assert(wrapper:find("chatwoo001", 1, true))
  local syntax = vim.system({ "sh", "-n", config.state_root .. "/remote-command-hook.sh" }):wait()
  assert_equal(0, syntax.code)

  local fake_ssh = vim.fn.tempname()
  local fake_args = vim.fn.tempname()
  local fake_stdin = vim.fn.tempname()
  require("remote-mirror.util").write_file(
    fake_ssh,
    "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$REMOTE_MIRROR_TEST_ARGS\"\ncat > \"$REMOTE_MIRROR_TEST_STDIN\"\n"
  )
  assert(vim.uv.fs_chmod(fake_ssh, 493))
  config.ssh_command = fake_ssh
  local hooked_transport = require("remote-mirror.transport").new(config, function()
    return { code = 0, stdout = "", stderr = "" }
  end)
  local hooked_shell = hooked_transport:rsync_shell()
  local hooked_wrapper = config.state_root .. "/remote-command-hook.sh"
  local fake_result = vim.system({
    hooked_wrapper,
    "server",
    "rsync",
    "--server",
    "weird ' \" $ ;",
  }, {
    stdin = "payload",
    env = {
      REMOTE_MIRROR_HOOK_PASSWORD = "p@ss'w!rd",
      REMOTE_MIRROR_TEST_ARGS = fake_args,
      REMOTE_MIRROR_TEST_STDIN = fake_stdin,
    },
  }):wait()
  assert_equal(0, fake_result.code)
  assert(hooked_shell:find("remote%-command%-hook%.sh", 1, false))
  local captured_args = require("remote-mirror.util").read_file(fake_args)
  assert(captured_args:find('su %-s /bin/sh %-c "$1" chatwoo001', 1, false), captured_args)
  assert(captured_args:find("weird", 1, true), captured_args)
  assert_equal("p@ss'w!rd\npayload", require("remote-mirror.util").read_file(fake_stdin))

  local command_capture = vim.fn.tempname()
  local command_hook = vim.fn.tempname()
  local executing_ssh = vim.fn.tempname()
  require("remote-mirror.util").write_file(
    command_hook,
    "#!/bin/sh\nprintf '%s' \"$1\" > \"$REMOTE_MIRROR_TEST_COMMAND\"\n"
  )
  assert(vim.uv.fs_chmod(command_hook, 493))
  config.mirror_root = vim.fn.tempname()
  require("remote-mirror.util").ensure_dir(config.mirror_root)
  require("remote-mirror.util").write_file(
    config.mirror_root .. "/onRemoteCommand",
    require("remote-mirror.util").read_file(command_hook)
  )
  require("remote-mirror.util").write_file(
    executing_ssh,
    [[#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-F|-p|-l) shift 2 ;;
    *) shift; break ;;
  esac
done
exec /bin/sh -c "$1"
]]
  )
  assert(vim.uv.fs_chmod(executing_ssh, 493))
  config.ssh_command = executing_ssh
  local command_transport = require("remote-mirror.transport").new(config, function()
    return { code = 0, stdout = "", stderr = "" }
  end)
  local command_wrapper = config.state_root .. "/remote-command-hook.sh"
  command_transport:rsync_shell()
  local command_result = vim.system({
    command_wrapper,
    "server",
    "rsync",
    "--server",
    "weird ' \" $ ;",
  }, {
    env = {
      REMOTE_MIRROR_TEST_COMMAND = command_capture,
    },
  }):wait()
  assert_equal(0, command_result.code)
  assert_equal(
    [=['rsync' '--server' 'weird '\'' " $ ;']=],
    require("remote-mirror.util").read_file(command_capture)
  )

  local direct_capture = vim.fn.tempname()
  require("remote-mirror.util").write_file(
    config.mirror_root .. "/onRemoteCommand",
    "#!/bin/sh\nprintf '%s' \"$1\" > \"$REMOTE_MIRROR_TEST_DIRECT_COMMAND\"\n"
  )
  local direct_transport = require("remote-mirror.transport").new(config)
  local direct_result = direct_transport:ssh("printf 'direct; $value'", {
    env = { REMOTE_MIRROR_TEST_DIRECT_COMMAND = direct_capture },
  })
  assert_equal(0, direct_result.code)
  assert_equal("printf 'direct; $value'", require("remote-mirror.util").read_file(direct_capture))
end)

test("workspace command hooks reject SCP", function()
  local mirror_root = vim.fn.tempname()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/website",
    mirror_root = mirror_root,
    transfer = "scp",
  })
  require("remote-mirror.util").write_file(config.mirror_root .. "/onRemoteCommand", "exec \"$1\"\n")
  local ok, err = pcall(require("remote-mirror.transport").new, config, function()
    return { code = 0, stdout = "", stderr = "" }
  end)
  assert_equal(false, ok)
  assert(err:find("requires transfer = rsync", 1, true), err)
end)

test("lifecycle hooks run with workspace environment", function()
  local mirror_root = vim.fn.tempname()
  local config = require("remote-mirror.config").normalize({
    name = "website",
    host = "server",
    user = "deploy",
    remote_root = "/srv/website",
    mirror_root = mirror_root,
  })
  require("remote-mirror.util").write_file(
    config.mirror_root .. "/onConnected",
    "printf '%s\\n%s\\n%s' \"$REMOTE_MIRROR_WORKSPACE\" \"$REMOTE_MIRROR_USER\" \"$REMOTE_MIRROR_REMOTE_ROOT\" > hook-output\n"
  )
  require("remote-mirror.hooks").run(config, "onConnected")
  assert_equal("website\ndeploy\n/srv/website", require("remote-mirror.util").read_file(config.mirror_root .. "/hook-output"))
end)

-- Only root can read a file whose mode denies it, so the permission tests
-- verify the situation they need before asserting anything about it.
local function make_unreadable(path)
  vim.uv.fs_chmod(path, 0)
  return io.open(path, "rb") == nil
end

test("an unreadable file is reported instead of counting as absent", function()
  local util = require("remote-mirror.util")
  local root = vim.fn.tempname()
  util.ensure_dir(root)
  util.write_file(util.join(root, "readable.txt"), "readable\n")
  util.write_file(util.join(root, "secret.txt"), "secret\n")
  if not make_unreadable(util.join(root, "secret.txt")) then
    return
  end

  local hash, reason = util.hash_file(util.join(root, "secret.txt"))
  assert_equal(nil, hash)
  assert(reason, "an unreadable file must report why")
  assert_equal(nil, util.hash_file(util.join(root, "missing.txt")))

  local files, unreadable = util.walk_files(root)
  assert_equal(nil, files["secret.txt"])
  assert(files["readable.txt"])
  assert_equal(1, #unreadable)
  assert_equal("secret.txt", unreadable[1].path)
  assert(util.unreadable_message(unreadable):find("secret.txt", 1, true))
end)

test("an unlistable directory is reported instead of counting as empty", function()
  local util = require("remote-mirror.util")
  local root = vim.fn.tempname()
  util.ensure_dir(util.join(root, "locked"))
  util.write_file(util.join(root, "locked", "inside.txt"), "inside\n")
  vim.uv.fs_chmod(util.join(root, "locked"), 0)
  if vim.uv.fs_scandir(util.join(root, "locked")) ~= nil then
    vim.uv.fs_chmod(util.join(root, "locked"), 448)
    return
  end

  local files, unreadable = util.walk_files(root)
  assert_equal({}, files)
  assert_equal(1, #unreadable)
  assert_equal("locked", unreadable[1].path)
  vim.uv.fs_chmod(util.join(root, "locked"), 448)

  -- A mirror that has not been created yet is absent, not unreadable.
  local _, absent = util.walk_files(vim.fn.tempname())
  assert_equal({}, absent)
end)

test("an unreadable file is never pushed as a deletion", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  local path = util.join(config.source_root, "secret.txt")
  util.write_file(path, "secret\n")
  if not make_unreadable(path) then
    return
  end

  local deleted, uploaded = {}, {}
  local State = require("remote-mirror.state")
  local state = State.new(config)
  state.data.files["secret.txt"] = {
    remote_hash = "baseline",
    local_hash = "baseline",
    materialized = true,
  }
  local core = require("remote-mirror.core").new(config, {
    state = state,
    transport = {
      inspect = function()
        return { hash = "baseline" }
      end,
      upload = function(_, name)
        table.insert(uploaded, name)
      end,
      delete = function(_, name)
        table.insert(deleted, name)
      end,
    },
  })

  local pushed, message = pcall(core.push_file, core, "secret.txt", true)
  assert_equal(false, pushed)
  assert(message:find("not treated as a deletion", 1, true), message)
  assert_equal({}, deleted)
  assert_equal({}, uploaded)

  local bulk_ok, bulk_message = pcall(core.push, core)
  assert_equal(false, bulk_ok)
  assert(bulk_message:find("could not be read", 1, true), bulk_message)
  assert_equal({}, deleted)
end)

test("an unreadable file does not enter the upload queue", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    watch = false,
    debounce_ms = 10,
  })
  local util = require("remote-mirror.util")
  util.ensure_dir(config.source_root)
  local path = util.join(config.source_root, "secret.txt")
  util.write_file(path, "secret\n")
  if not make_unreadable(path) then
    return
  end

  local deleted = {}
  local core = require("remote-mirror.core").new(config, {
    transport = {
      inspect = function()
        return nil
      end,
      upload = function() end,
      delete = function(_, name)
        table.insert(deleted, name)
      end,
    },
  })
  core.state.data.files["secret.txt"] = {
    remote_hash = "baseline",
    local_hash = "baseline",
    materialized = true,
  }
  core:schedule_upload("secret.txt")
  assert_equal({}, core.pending)
  vim.wait(100)
  assert_equal({}, deleted)
end)

test("a failed connection forgets the workspace password", function()
  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
  })
  manager:add({
    name = "website",
    host = "server",
    remote_root = "/srv/website",
    auth = "password",
    mirror_root = vim.fn.tempname(),
  })
  manager:set_password("website", "wrong")
  manager:set_sudo_password("website", "wrong-sudo")
  manager:set_hook_password("website", "wrong-hook")

  local failure
  manager:connect_async("website", "force_pull", function(ok, err)
    failure = not ok and err or nil
  end)
  assert(vim.wait(5000, function()
    return failure ~= nil
  end), "the connection to a nonexistent host must fail")

  assert_equal(false, manager:has_password("website"))
  assert_equal(false, manager:has_sudo_password("website"))
  assert_equal(false, manager:has_hook_password("website"))
end)

test("disconnecting forgets the workspace password", function()
  local config = require("remote-mirror.config").normalize({
    name = "website",
    host = "server",
    remote_root = "/srv/website",
    mirror_root = vim.fn.tempname(),
    watch = false,
  })
  local core = require("remote-mirror.core").new(config)
  core:ensure_layout()
  local manager = require("remote-mirror.manager").new({
    registry_path = vim.fn.tempname() .. "/workspaces.json",
  })
  manager:set_password("website", "session-secret")
  manager:set_sudo_password("website", "session-sudo")
  manager:_activate(core)

  manager:disconnect()
  assert_equal(false, manager:has_password("website"))
  assert_equal(false, manager:has_sudo_password("website"))
end)

test("queued operations report themselves while they run", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local Progress = require("remote-mirror.progress")
  Progress.reset()
  assert_equal("", Progress.status())

  local core = require("remote-mirror.core").new(config)
  local observed, completed
  core:enqueue(function()
    observed = Progress.status()
    require("remote-mirror.async").runner({ "sh", "-c", "true" })
  end, function(ok)
    completed = ok
  end, "pulling example")

  assert(vim.wait(1000, function()
    return completed ~= nil
  end))
  assert_equal(true, completed)
  assert(observed:find("pulling example", 1, true), observed)
  assert_equal("", Progress.status())
  assert_equal(false, Progress.active())
end)

test("rsync transfer progress reaches the status indicator", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
  })
  local Progress = require("remote-mirror.progress")
  Progress.reset()
  local handle = Progress.start("pulling example")

  local captured
  local runner = function(command, options)
    captured = { command = command, options = options }
    options.on_stdout("\r    103,809,024  31%   11.03MB/s    0:00:19 (xfr#118, to-chk=724/1042)\r")
    return { code = 0, stdout = "", stderr = "" }
  end
  require("remote-mirror.transport").new(config, runner):pull("/tmp/filter")

  assert_contains(captured.command, "--info=progress2")
  local status = Progress.status()
  assert(status:find("31%%"), status)
  assert(status:find("99.0 MiB", 1, true), status)
  assert(status:find("318/1042 files", 1, true), status)
  handle:finish()
  assert_equal("", Progress.status())
end)

test("rsync progress can be turned off per workspace", function()
  local config = require("remote-mirror.config").normalize({
    host = "server",
    remote_root = "/srv/example",
    mirror_root = vim.fn.tempname(),
    rsync_progress = false,
  })
  local captured
  local runner = function(command, options)
    captured = { command = command, options = options }
    return { code = 0, stdout = "", stderr = "" }
  end
  require("remote-mirror.transport").new(config, runner):push("/tmp/filter")
  assert_equal(nil, captured.options.on_stdout)
  for _, argument in ipairs(captured.command) do
    assert(argument ~= "--info=progress2", "progress must not be requested when it is disabled")
  end
end)

test("watched output is still returned to the caller that parses it", function()
  local collected = {}
  local result = require("remote-mirror.process").run({ "sh", "-c", "printf watched" }, {
    on_stdout = function(chunk)
      table.insert(collected, chunk)
    end,
  })
  assert_equal("watched", result.stdout)
  assert_equal("watched", table.concat(collected))
end)

test("transfer failures are summarized without losing their output", function()
  local notify = require("remote-mirror.notify")
  local described = notify.describe(
    "ssh failed (255): deploy@server: Permission denied, please try again.\ndeploy@server: Permission denied (publickey,password)."
  )
  assert_equal("the SSH password was rejected", described.summary)
  assert(described.detail:find("publickey", 1, true), described.detail)

  local plain = notify.describe("pulled 12 remote files")
  assert_equal("pulled 12 remote files", plain.summary)
  assert_equal(nil, plain.detail)

  local before = #notify.history
  notify.show("could not resolve hostname server", vim.log.levels.ERROR)
  assert_equal(before + 1, #notify.history)
  local entry = notify.history[#notify.history]
  assert_equal("error", entry.level_name)
  assert_equal("the host name could not be resolved", entry.summary)
  assert(find_prefixed(notify.messages(), entry.at .. "  error"), "the log must keep the message")
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
