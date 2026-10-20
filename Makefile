NVIM ?= nvim
# Spec file order: name (default), reverse, or shuffle (SEED repeats one).
ORDER ?= name
SEED ?=
# Only the spec files whose path holds this text.
ONLY ?=

.PHONY: test test-core bench demo

test:
	ADO_TEST_ORDER=$(ORDER) ADO_TEST_SEED=$(SEED) ADO_TEST_ONLY=$(ONLY) $(NVIM) --headless -u NONE -l tests/run.lua

test-core:
	ADO_TEST_ORDER=$(ORDER) ADO_TEST_SEED=$(SEED) ADO_TEST_ONLY=$(ONLY) $(NVIM) --headless -u NONE -l tests/run.lua core

# Timings of the views' re-pad; not part of test, as they vary by machine.
bench:
	$(NVIM) --headless -u NONE -l tests/bench/views_bench.lua

# The README's GIFs, from scripts/demo/*.tape on the fake gateway; needs
# vhs, ttyd and ffmpeg on PATH. TAPES=scripts/demo/item.tape makes one.
VHS ?= vhs
TAPES ?= $(filter-out scripts/demo/settings.tape,$(wildcard scripts/demo/*.tape))

demo:
	@for t in $(TAPES); do echo "$$t"; NVIM=$(NVIM) $(VHS) -q "$$t" || exit 1; done
