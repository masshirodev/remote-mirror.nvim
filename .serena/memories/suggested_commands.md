# Suggested commands
- Test: `NVIM_LOG_FILE=/tmp/remote-mirror-tests.log make test`
- Check patch whitespace: `git diff --check`
- Inspect working tree: `git status --short`
- Validate installed config headlessly with `NVIM_LOG_FILE=/tmp/remote-mirror-installed.log nvim --headless -i NONE '+lua require("remote-mirror")' +qa` when installation wiring is in scope.