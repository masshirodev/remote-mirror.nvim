# Project core
- Neovim plugin implementing named SSH workspaces backed by private local sparse mirrors.
- Source modules live under `lua/remote-mirror/`; plugin loader is `plugin/remote-mirror.lua`.
- `manager.lua` owns registry, credentials, connection lifecycle; `core.lua` owns sync state and conflict behavior; `transport.lua` is the SSH/rsync boundary; `ui.lua` owns workspace and explorer buffers.
- Remote project is authoritative until a guarded local upload succeeds. Never silently overwrite a remotely changed file.
- Passwords are transient in-memory data and must never enter registry/state files.
- Read `mem:tech_stack` for runtime details, `mem:conventions` for invariants, and `mem:task_completion` before handoff.