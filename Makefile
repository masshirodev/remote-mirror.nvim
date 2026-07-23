.PHONY: test

test:
	nvim --headless --clean -u tests/minimal.lua -l tests/run.lua
