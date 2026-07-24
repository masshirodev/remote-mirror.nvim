# remote-mirror.nvim

Use projects on SSH hosts as named Neovim workspaces while keeping Neovim,
language servers, formatters, and other developer tools local.

The plugin owns the local sparse-mirror paths. Users enter through
`:RemoteMirrorConnect`, choose a workspace, and browse remote paths rather than
navigating a `source/` directory.

## Current capabilities

- persisted named workspaces;
- connection and workspace screens built into Neovim;
- interactive browsing of the remote host when choosing a project root;
- `rsync` bulk transfer with an SCP fallback for hosts without rsync;
- complete remote file manifest with lazy opening of ignored files;
- automatic uploads for Neovim saves and external filesystem changes;
- explicit push, refresh, disconnect, and conflict resolution;
- hash checks that prevent silent remote overwrites.

## Requirements

- Neovim 0.10 or newer
- `ssh`
- either `rsync` on both hosts, or local `scp` plus an SCP/SFTP-capable SSH server
- GNU `find`, `stat`, `sha256sum`, and `du` on the remote host

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
and file-transfer method, then pick the remote project root by browsing the
host or by typing a path. Use rsync when it is available;
choose SCP when the remote host does not provide rsync.
Workspaces are persisted in Neovim's data directory and appear on later
connect screens.

The remote project root is chosen on a browser screen that lists the remote
host's directories and files, starting in the login home directory. Typing a
full path is still possible with `i`.

| Key | Action |
| --- | --- |
| `Enter` | Open the directory under the cursor |
| `-` | Go to the parent directory |
| `.` | Use the current directory as the project root |
| `i` | Type a remote path and go there |
| `H` | Show or hide dotfiles |
| `r` | List the current directory again |
| `q` | Cancel and return to the connection screen |

Listings are read over the same SSH connection the workspace will use, so an
unreachable host, a wrong password, or an unreadable directory is reported
before the workspace is registered.

After the remote path is chosen, the plugin validates it and displays its
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

Press `d` to delete a workspace after confirmation, choosing whether to keep
its local mirror. Keeping it preserves the mirrored files and synchronization
state, so adding the same workspace again recovers them. Deleting it names the
exact directory in a second confirmation and removes it permanently; the remote
workspace is never touched.

A name identifies both the registration and the local mirror directory, so
reusing one rebinds the registration and points the new endpoint at the
existing mirror. The add screen reports the collision as soon as the name is
entered and offers to choose another one.

Each mirror also records the host and remote path it was built from. When a
name ends up pointing somewhere else, connecting is refused and names the
mirror directory involved, because that mirror's files and recorded hashes
describe the previous endpoint; a force push would otherwise upload one
server's project into another. Rename the workspace, or run
`:RemoteMirrorReset {workspace}` to delete that mirror and start the name over
against the new endpoint. Mirrors created before this was recorded are adopted
by whichever workspace uses them.

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

The workspace screen lists the complete remote manifest. Pressing Enter on a
file that has not been materialized locally downloads it before opening it.

| Marker | Meaning |
| --- | --- |
| `↓` | Not downloaded yet |
| `~` | Changed on the remote since the last transfer |
| `x` | Deleted on the remote since the last transfer |
| `!` | Conflict recorded |

`~` and `x` come from the last refresh or poll, which observe the remote
without advancing the transfer baseline, so a file stays marked until a pull,
push, or resolution reconciles it.

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
| `:RemoteMirrorDisconnect` | Leave the active workspace, keeping its mirror |
| `:RemoteMirrorReset {workspace}` | Delete a local mirror, keeping its registration |
| `:RemoteMirrorPull` | Pull while protecting locally changed files |
| `:RemoteMirrorPush` | Push locally changed, created, and deleted files |
| `:RemoteMirrorRefresh` | Compare the remote manifest without transferring |
| `:RemoteMirrorConflicts` | Display recorded conflicts |
| `:RemoteMirrorResolve {path} pull` | Replace the local file with the remote version |
| `:RemoteMirrorResolve {path} push` | Explicitly overwrite the remote version |

## Deleting a local mirror

`:RemoteMirrorReset {workspace}` deletes a workspace's mirror directory while
keeping its registration, so the next connection starts from the remote
workspace again. It completes registered workspace names, and it refuses to run
against a connected workspace, from inside the mirror itself, or when
`source_root`, `state_root`, or `tree_root` was configured outside the mirror
directory. Those paths are removed manually, because the plugin only deletes
the layout it owns.

## Disconnecting

`:RemoteMirrorDisconnect` stops watching the active workspace, stops uploading
saves, and restores the working directory that was current before connecting.
The local mirror, its synchronization state, and any open buffers are left
alone, so reconnecting later reconciles from that mirror instead of pulling
everything again. The session password is also kept, so a reconnect within the
same session does not prompt for it.

The command refuses to run while a pull, push, refresh, or upload is still in
flight, so a transfer is never abandoned halfway. Use
`:RemoteMirrorDisconnect!` to leave anyway; queued operations are cancelled and
debounced uploads that had not started yet are discarded, which is reported in
the confirmation message. An operation that is already running still finishes.

## Open buffers

Pulls, lazy downloads, and conflict resolutions rewrite files that may already
be open. Those buffers are reloaded so their contents match the mirror, without
depending on `'autoread'`.

A buffer with unsaved changes is never reloaded, because its text is the only
copy of that work. Those paths are named in a warning instead, leaving the
choice between saving over the pulled file and discarding the buffer.

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

The preflight measures every directory while it sizes the workspace, so the
rules screen also lists the heaviest directories that neither the built-in
defaults nor an existing rule already covers:

```gitignore
# Largest directories the rules above do not cover:
#    512.0 MiB  storage/
#    331.0 MiB  public/uploads/
#
# Uncomment any of these to keep that directory on the server.
# storage/
# public/uploads/
```

Suggestions arrive commented out, so nothing is excluded without an explicit
edit. A directory is suggested when it holds at least 10 MiB, up to eight of
them, and a directory is skipped when one of its parents is already listed.

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
