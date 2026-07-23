# Remote Workspace Mirror

## Summary

Build a Neovim remote-workspace plugin that keeps Neovim and developer tools
local while treating a server project as the authoritative workspace.

The plugin exposes the complete remote tree, mirrors source files locally, and
downloads ignored files only when the user opens them. Saves upload changes
back to the server.

```text
remote project
      │ initial sync and remote tree manifest
      ▼
local sparse mirror
      │ local Neovim, LSPs, Node, Cargo, Python, formatters
      │ save
      ▼
remote file overwritten after conflict checks
```

This is different from `remote-nvim.nvim`: Neovim and tooling execute locally,
so the user's existing toolchains remain available.

## Goals

- Keep source files mirrored locally by default.
- Show the complete server-side file tree, including dependencies and build
  artifacts.
- Download ignored or remote-only files lazily when opened.
- Upload local changes on save.
- Preserve normal local LSP, formatter, compiler, and language-tool behavior.
- Detect remote changes before overwriting them.
- Support explicit pull, push, refresh, and conflict-resolution commands.

## Non-goals

- Running local tools against files that do not exist locally.
- Making remote dependencies magically available to every local language
  server.
- Treating the remote tree as a transparent local filesystem in the first
  version.
- Silently overwriting remote changes.

## Workspace model

Each remote project has a local mirror with three logical layers:

```text
.remote-mirror/<project>/
  source/          # mirrored source and other selected files
  .remote-tree/    # placeholders for remote-only files
  .remote-state/   # manifest, hashes, sync metadata, conflicts
```

The user opens `source/` as the local project root. A merged explorer view
combines materialized files with entries from the remote manifest.

Source files are materialized during the initial sync. Files excluded by
`.remoteignore` remain remote-only until opened or explicitly downloaded.

## `.remoteignore`

Use gitignore-style patterns, evaluated against paths relative to the remote
project root:

```gitignore
node_modules/
target/
dist/
build/
.cache/
*.log

# Re-include a useful generated file.
!src/generated/schema.json
```

The default rules should be conservative. A project can override them with a
`.remoteignore` file stored at its remote root. The plugin should make the
default policy configurable rather than hardcoding language-specific boards of
files.

Useful future options include:

- always mirror;
- mirror on open;
- never mirror;
- mirror directory metadata only.

## Remote tree and placeholders

The remote tree is obtained through SSH using a manifest operation. The
manifest includes at least:

- relative path;
- file type;
- size;
- modification time;
- content hash when affordable;
- materialization state.

Ignored files can be represented locally by placeholder entries with a hidden
extension, for example `package.json.__remote`. The explorer strips the
extension when displaying the entry. Opening the entry downloads the real file
into `source/` and opens the materialized path.

The placeholder mechanism must not expose empty files to local LSPs or tools.
The first implementation should therefore use a custom merged explorer rather
than pretending placeholders are ordinary project files. A later integration
could add adapters for neo-tree or nvim-tree.

Alternative implementation: create zero-byte files at their canonical paths
and intercept reads with `BufReadCmd`. This is simpler to prototype but risks
local tools indexing empty placeholder files, so it should not be the default.

## Synchronization

### Initial setup

1. Connect to the configured SSH host.
2. Discover the remote project root.
3. Read `.remoteignore` and apply defaults.
4. Build a remote manifest.
5. Download all non-ignored source files using `rsync` or a batched SSH
   transfer.
6. Store hashes and remote metadata in `.remote-state/`.
7. Display the merged local and remote tree.

The initial transfer should use `rsync`, not one SSH transfer per file.

### Opening a remote-only file

1. Select the entry from the merged explorer.
2. Check whether its remote hash has changed since the last manifest.
3. Download it into `source/`.
4. Record it as materialized.
5. Open the local path in Neovim.

### Saving

On `BufWritePost` for a mirrored file:

1. Hash the local file.
2. Query or compare the remote metadata.
3. If the remote file changed unexpectedly, create a conflict and do not
   overwrite it silently.
4. Otherwise upload the file, preferably through a debounced batch queue.
5. Update local and remote hashes.

The first version may upload individual files on save. A short queue/debounce
window is preferable when formatters or generators save several files at once.

### Creates, deletes, and renames

Save hooks alone are insufficient. The plugin must also handle:

- newly created files;
- deleted files;
- renames;
- directory creation;
- remote files removed outside Neovim.

Provide explicit commands for reconciliation and use the manifest to detect
changes that buffer events cannot observe.

## Conflict policy

The remote project is authoritative until a local change is uploaded. Before
uploading, compare the remote hash with the hash recorded at the last sync.

Possible commands:

```vim
:RemoteMirrorPull
:RemoteMirrorPush
:RemoteMirrorRefresh
:RemoteMirrorConflicts
:RemoteMirrorResolve
```

Recommended default behavior is to stop and report a conflict. Force
overwrite should require an explicit command or confirmation.

## Tooling considerations

Local tools work naturally for mirrored source files, but ignored dependencies
may still be required by language servers:

- TypeScript may need `node_modules` for module resolution.
- Rust tooling may need workspace metadata and local registry caches.
- Python tooling may need a virtual environment or installed packages.
- Generated schemas and code may need selective materialization.

The plugin should support per-project materialization rules so users can keep
large dependency trees remote while mirroring the metadata or generated files
their local tools require.

## Transport

Use batched SSH operations rather than one connection per file:

- `rsync` for initial sync and bulk reconciliation;
- `scp` or rsync for individual saves;
- SSH commands for manifest, hashes, mkdir, delete, and conflict checks.

The transport should reuse the user's SSH config, identity, port, and host
aliases.

## Proposed MVP

1. Configure one SSH host and one remote project root.
2. Download all files except `.remoteignore` matches.
3. Open the local mirror with normal Neovim tooling.
4. Upload changed files on save.
5. Expose explicit pull and push commands.
6. Add remote manifest refresh and basic conflict detection.
7. Add a merged remote tree with lazy download for ignored files.

The merged tree and lazy materialization can follow after the basic mirror is
reliable. They should share the same manifest and sync state format.

## Relationship to `remote-nvim.nvim`

This should be a separate workflow or plugin. `remote-nvim.nvim` is designed
around running Neovim and its tooling on the remote host. A local mirror needs
local Neovim ownership, local project paths, and synchronization lifecycle
management.

An eventual integration could reuse its SSH host selection UI, but the
execution model should remain separate and explicit.
