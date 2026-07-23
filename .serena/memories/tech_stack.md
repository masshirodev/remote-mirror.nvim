# Tech stack
- Lua Neovim plugin targeting Neovim 0.10+.
- Uses built-in `vim.*`, libuv filesystem APIs, `ssh`, `rsync`, and GNU remote utilities (`find`, `stat`, `sha256sum`).
- No external Lua plugin dependency.
- Tests run as a headless Neovim Lua script via Make.