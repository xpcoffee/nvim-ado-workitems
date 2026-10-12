NVIM ?= nvim

.PHONY: test test-core

test:
	$(NVIM) --headless -u NONE -l tests/run.lua

test-core:
	$(NVIM) --headless -u NONE -l tests/run.lua core
