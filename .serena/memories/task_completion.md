# Task completion
- Run `NVIM_LOG_FILE=/tmp/remote-mirror-tests.log make test`.
- Run `git diff --check`.
- Update README and design markdown when user-facing sync semantics change.
- If local Neovim installation behavior changed, validate the active installed config headlessly with `-i NONE`.
- Preserve unrelated working-tree changes; do not commit or push unless requested.