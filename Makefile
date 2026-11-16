NVIM_BIN ?= nvim
.PHONY: test test-real

# GNU timeout guards against hangs; Windows' own `timeout` only pauses.
ifeq ($(OS),Windows_NT)
TIMEOUT =
else
TIMEOUT = timeout $(1)
endif

# Offline: fake agents only, no login, network or inference.
test:
	$(call TIMEOUT,300) $(NVIM_BIN) --clean --headless -l tests/run.lua $(FILTER)

# Opt-in: BACKEND=codex|copilot, REAL_ARGS=--allow-inference consumes quota.
test-real:
	$(call TIMEOUT,180) $(NVIM_BIN) --clean --headless -l tests/real.lua $(BACKEND) $(REAL_ARGS)
