# remote-mirror.nvim

Use projects on SSH hosts as named Neovim workspaces while keeping Neovim,
language servers, formatters, and other developer tools local.

The plugin owns the local sparse-mirror paths. Users enter through
`:RemoteMirrorConnect`, choose a workspace, and browse remote paths rather than
navigating a `source/` directory.

## Current capabilities

- persisted named workspaces;
- connection and workspace screens built into Neovim;
- `rsync` bulk transfer with an SCP fallback for hosts without rsync;
- complete remote file manifest with lazy opening of ignored files;
- automatic uploads for Neovim saves and external filesystem changes;
- explicit push, refresh, and conflict resolution;
- hash checks that prevent silent remote overwrites.

## Requirements

- Neovim 0.10 or newer
- `ssh`
- either `rsync` on both hosts, or local `scp` plus an SCP/SFTP-capable SSH server
- GNU `find`, `stat`, and `sha256sum` on the remote host

SSH hosts, ports, and identities come from the user's normal SSH
configuration.

## Setup

With a plugin manager, an empty setup is enough:

```lua
require("remote-mirror").setup()
```

With [lazy.nvim](https://github.com/folke/lazy.nvim), add this plugin spec:

```lua
{
  "masshirodev/remote-mirror.nvim",
  lazy = false,
  keys = {
    {
      "<leader>rm",
      "<cmd>RemoteMirrorConnect<cr>",
      desc = "Remote Mirror workspaces",
    },
  },
}
```

The plugin initializes itself when loaded. To develop against a local checkout,
replace the repository string with:

```lua
{
  dir = "/path/to/remote-mirror.nvim",
  name = "remote-mirror.nvim",
  lazy = false,
}
```

Then run:

```vim
:RemoteMirrorConnect
```

Press `a` to add a workspace by name, SSH host, SSH port, user, authentication,
file-transfer method, and remote project root. Use rsync when it is available;
choose SCP when the remote host does not provide rsync.
Workspaces are persisted in Neovim's data directory and appear on later
connect screens.

After the remote path is entered, the plugin validates it and displays its
total size and file count. The workspace is registered only after the user
confirms that summary.

If `.remoteignore` is missing, the preflight offers an editable rules screen,
continuing with built-in ignores, or cancelling. Workspaces over 100 MiB or
10,000 files receive a stronger recommendation. The rules screen shows the
estimated filtered size before it writes `.remoteignore` or registers the
workspace. Rsync uses a dry run; SCP calculates the estimate from the remote
manifest.

The form resolves defaults with `ssh -G`, so aliases, `Include` files, `User`,
`Port`, and identity settings from `~/.ssh/config` are honored. A blank port or
user keeps SSH configuration in control; without a configured port, SSH uses
`22`. Press `e` on an existing workspace to edit its connection.

If OpenSSH rejects a misowned system configuration, discovery retries with
`~/.ssh/config` explicitly. When no user config exists, it uses `/dev/null` to
bypass only the broken system file.

Press `d` to remove a workspace registration after confirmation. Its backing
mirror and synchronization state are preserved, so adding the same workspace
again recovers it.

Workspaces can also be declared:

```lua
require("remote-mirror").setup({
  workspaces = {
    {
      name = "website",
      host = "my-server",
      user = "deploy",
      port = 65002,
      transfer = "scp",
      remote_root = "/srv/website",
      scp_command = "/usr/bin/scp",
      scp_args = { "-O" },
    },
  },
})
```

`transfer` defaults to `"rsync"` and can be set to `"scp"` globally or per
workspace. SCP keeps ignore, deletion, review, and conflict semantics, but bulk
operations transfer included files individually and are therefore slower on
large workspaces.

Executable paths and extra arguments can also be overridden globally or per
workspace:

```lua
require("remote-mirror").setup({
  ssh_command = "/opt/openssh/bin/ssh",
  ssh_args = { "-o", "Compression=yes" },
  rsync_command = "/opt/rsync/bin/rsync",
  rsync_args = { "-az", "--partial" },
  scp_command = "/opt/openssh/bin/scp",
  scp_args = { "-O" },
  remote_find_command = "/usr/local/bin/gfind",
  remote_stat_command = "/usr/local/bin/gstat",
  remote_sha256sum_command = "/usr/local/bin/gsha256sum",
  remote_du_command = "/usr/local/bin/gdu",
})
```

Remote command overrides must accept the GNU-compatible arguments used by the
plugin. `scp_args = { "-O" }` is useful for servers that require the legacy SCP
protocol instead of modern SFTP-backed SCP.

Leave `auth` unset (or use `auth = "ssh"`) for SSH config, agent, and identity
authentication. Password authentication is selected interactively. Passwords
are kept only in Neovim memory for the active session and are requested again
after restarting Neovim; they are never written to the workspace registry or
mirror state.

The first connection confirms an initial pull. When a local mirror already
exists, connecting requires one of three explicit strategies:

- **Force pull (remote wins):** overwrite differing local files and delete
  files that exist only in the local mirror.
- **Review changed paths:** compare file content, then open one
  editable buffer containing a `pull`, `push`, or `skip` action for every
  changed path. Applying the buffer requires confirmation.
- **Force push (local wins):** overwrite differing remote files and delete
  files that exist only in the remote workspace.

Force pull and force push each show a separate destructive confirmation. The
review buffer defaults every path to `pull`, because the running remote project
is treated as authoritative until the user deliberately uploads a local edit.
A reviewed push is rejected if that remote path changes again between
comparison and application.

These strategies apply to the mirrored scope. Paths excluded by the combined
built-in and `.remoteignore` rules remain protected from bulk transfer and
bulk deletion.

After reconciliation, Neovim's working directory is set to the private mirror
root so local tools resolve project-relative paths normally, but the plugin UI
exposes the workspace name and remote-relative paths.

Connection, pull, push, refresh, lazy download, and watched-file uploads run
through a serialized asynchronous queue, so SSH, rsync, and SCP do not block
Neovim's UI. SSH connection establishment defaults to a 10-second timeout and
password authentication is limited to one prompt.

## Workspace screen

The workspace screen lists the complete remote manifest. `↓` marks a file that
has not been materialized locally. Pressing Enter downloads it before opening
it.

| Key | Action |
| --- | --- |
| `Enter` | Open or lazily download a file |
| `c` | Return to the workspace connection screen |
| `p` | Pull |
| `P` | Push |
| `r` | Refresh the remote manifest |

## Synchronization commands

| Command | Purpose |
| --- | --- |
| `:RemoteMirrorConnect` | Open the workspace connection screen |
| `:RemoteMirrorPull` | Pull while protecting locally changed files |
| `:RemoteMirrorPush` | Push locally changed, created, and deleted files |
| `:RemoteMirrorRefresh` | Compare the remote manifest without transferring |
| `:RemoteMirrorConflicts` | Display recorded conflicts |
| `:RemoteMirrorResolve {path} pull` | Replace the local file with the remote version |
| `:RemoteMirrorResolve {path} push` | Explicitly overwrite the remote version |

## Local file watching

The active workspace is watched recursively with libuv filesystem events.
Creates, changes, and deletes made by LSPs, formatters, generators, or user
scripts enter the same debounced upload path as `BufWritePost`.

New directories are discovered whenever the watcher rescans. Set `watch =
false` to disable external-change watching, or change `watch_debounce_ms`
(default `300`) and `debounce_ms` (default `200`) to tune batching.

## Ignore rules

The plugin combines conservative defaults with a `.remoteignore` file at the
remote project root. Rules use gitignore-style exclusions and `!` re-includes:

```gitignore
node_modules/
target/
*.log
!src/generated/schema.json
```

Ignored paths stay in the workspace manifest and download lazily when opened.

## Conflict behavior

Each file's state includes the hash from the last successful transfer.
Refreshes observe the current remote hash without advancing that baseline. A
push proceeds only when the current remote hash still matches the baseline.

When both sides changed, the operation records a conflict and leaves both files
untouched. Resolution always requires an explicit `pull` or `push` strategy.
Skipping a path in the connection review records a conflict while leaving both
sides untouched.

## Development

Run the headless test suite:

```sh
make test
```
