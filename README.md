# remote-mirror.nvim

Use projects on SSH hosts as named Neovim workspaces while keeping Neovim,
language servers, formatters, and other developer tools local.

The plugin owns the local sparse-mirror paths. Users enter through
`:RemoteMirrorConnect`, choose a workspace, and browse remote paths rather than
navigating a `source/` directory.

## Current capabilities

- persisted named workspaces;
- connection and workspace screens built into Neovim;
- initial and explicit pulls through `rsync`;
- complete remote file manifest with lazy opening of ignored files;
- automatic uploads for Neovim saves and external filesystem changes;
- explicit push, refresh, and conflict resolution;
- hash checks that prevent silent remote overwrites.

## Requirements

- Neovim 0.10 or newer
- `ssh`
- `rsync` on both the local and remote hosts
- GNU `find`, `stat`, and `sha256sum` on the remote host

SSH hosts, ports, and identities come from the user's normal SSH
configuration.

## Setup

With a plugin manager, an empty setup is enough:

```lua
require("remote-mirror").setup()
```

Then run:

```vim
:RemoteMirrorConnect
```

Press `a` to add a workspace by name, SSH host, and remote project root.
Workspaces are persisted in Neovim's data directory and appear on later
connect screens.

Workspaces can also be declared:

```lua
require("remote-mirror").setup({
  workspaces = {
    {
      name = "website",
      host = "my-server",
      remote_root = "/srv/website",
    },
  },
})
```

Connecting performs a conflict-safe pull, both initially and on later
connections. Neovim's working directory is set to the private mirror root so
local tools resolve project-relative paths normally, but the plugin UI exposes
the workspace name and remote-relative paths.

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

## Development

Run the headless test suite:

```sh
make test
```
