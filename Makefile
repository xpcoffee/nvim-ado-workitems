NVIM ?= nvim
# Spec file order: name (default), reverse, or shuffle (SEED repeats one).
ORDER ?= name
SEED ?=
# Only the spec files whose path holds this text.
ONLY ?=

.PHONY: test test-core bench

test:
	ADO_TEST_ORDER=$(ORDER) ADO_TEST_SEED=$(SEED) ADO_TEST_ONLY=$(ONLY) $(NVIM) --headless -u NONE -l tests/run.lua

test-core:
	ADO_TEST_ORDER=$(ORDER) ADO_TEST_SEED=$(SEED) ADO_TEST_ONLY=$(ONLY) $(NVIM) --headless -u NONE -l tests/run.lua core

# Timings of the views' re-pad; not part of test, as they vary by machine.
bench:
	$(NVIM) --headless -u NONE -l tests/bench/views_bench.lua
