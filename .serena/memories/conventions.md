# Conventions
- Keep modules dependency-light and built on Neovim APIs.
- Network operations exposed through the UI must use the serialized async queue; do not block Neovim with synchronous SSH/rsync.
- Local mirrors and synchronization state are preserved when workspace registration is deleted.
- State baselines advance only after a successful transfer. Observing a remote change alone must not bless it as synchronized.
- Broad or destructive synchronization needs explicit user choice and confirmation.
- Comments explain safety rationale, not mechanics. No emojis in code.