# PineVoice always-stream firmware: build & flash orchestration.
#
# WHERE EACH TARGET RUNS:
#   build*   -> inside the dev container (needs scons + the RISC-V toolchain).
#   package  -> inside the dev container (rebuilds both cores, zips artifacts).
#   flash*   -> on the HOST (flash-from-host.sh drives the native flashtool over
#               /dev/ttyACM*). Use flash-container* only when flashing from
#               inside the container instead.
#
# The E907 image embeds the compiled C906 core, so `build` builds C906 first.
# For iterating on app/src/wyoming/wyoming.c after the first full build, use
# `make build-fast` to skip the C906 rebuild.

REPO_ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
C906_DIR  := $(REPO_ROOT)/solutions/pinevoice_fw_c906
E907_DIR  := $(REPO_ROOT)/solutions/pinevoice_fw_e907

# Dev container: podman is preferred; override with `make env CONTAINER=docker`.
CONTAINER   := podman
IMAGE       := pinevoice-dev

.DEFAULT_GOAL := help

# ---- Dev container (run on the host) --------------------------------------

.PHONY: env
env: container-image ## Build the dev-container image if needed and open a shell in it (host)
	$(CONTAINER) run --rm -it \
		--userns=keep-id \
		-v "$(REPO_ROOT)":/workspace \
		-w /workspace \
		$(IMAGE) bash

.PHONY: container-image
container-image: ## Build the dev-container image (host; no-op if it already exists)
	@$(CONTAINER) image exists $(IMAGE) 2>/dev/null \
		|| $(CONTAINER) build -t $(IMAGE) -f $(REPO_ROOT)/.devcontainer/Dockerfile $(REPO_ROOT)/.devcontainer

# ---- Build (run inside the dev container) ---------------------------------

# The build needs scons and the RISC-V toolchain, which only exist inside the
# dev container. Fail fast with an explanation rather than letting the nested
# make die on a bare "scons: No such file or directory".
.PHONY: check-build-env
check-build-env:
	@command -v scons >/dev/null 2>&1 || { \
		echo "ERROR: 'scons' not found -- the firmware build must run INSIDE the dev container."; \
		echo "  The container provides scons and the RISC-V toolchain; the host does not."; \
		echo "  Open the VS Code Dev Container (or build/run .devcontainer/Dockerfile),"; \
		echo "  then run this build target from a shell inside it."; \
		echo "  Host-only targets (flash, flash-app, flash-console) still run on the host."; \
		exit 1; \
	}

.PHONY: build
build: build-c906 build-e907 ## Full build: C906 DSP core, then E907 firmware (container)

.PHONY: build-c906
build-c906: check-build-env ## Build the C906 DSP core (container)
	cd $(C906_DIR) && ./go

.PHONY: build-e907
build-e907: check-build-env ## Build the E907 main firmware (container; needs C906 built first)
	cd $(E907_DIR) && ./go

.PHONY: build-fast
build-fast: check-build-env ## Fast E907 rebuild, skips C906 (container; use after a full build)
	cd $(E907_DIR) && ./build.sh

# ---- Package (run inside the dev container) -------------------------------

.PHONY: package
package: check-build-env ## Clean-build both cores and zip a flashable firmware bundle (container)
	cd $(REPO_ROOT) && ./package.sh

# ---- Flash from the host --------------------------------------------------
#
# Put the board in download mode BEFORE running any flash target:
#   power off -> hold the center ring button -> power on while holding ->
#   run the flash target immediately (the ISP window times out quickly).

.PHONY: flash
flash: ## Full flash from host: firmware + partition + media + mfg (host)
	cd $(REPO_ROOT) && ./flash-from-host.sh

.PHONY: flash-app
flash-app: ## Quick app-only flash from host: firmware + partition (host)
	cd $(REPO_ROOT) && ./flash-from-host.sh --app-only

.PHONY: flash-console
flash-console: ## Full flash from host, then open the serial console (host)
	cd $(REPO_ROOT) && ./flash-from-host.sh --console

# ---- Flash from inside the container --------------------------------------

.PHONY: flash-container
flash-container: ## Flash firmware only, from inside the container (container)
	cd $(E907_DIR) && ./flash.sh

.PHONY: flash-container-full
flash-container-full: ## Flash firmware + media + mfg, from the container (container)
	cd $(E907_DIR) && ./flash.sh - full

# ---- Test -----------------------------------------------------------------
#
# This SDK has no host-side unit test suite; verification is on-device over
# Wyoming. `test`/`run-tests` document that check rather than stubbing tests.

.PHONY: test run-tests
test run-tests: ## Show how to verify always-stream on a running device
	@echo "No host test suite in this SDK. Verify on the device over Wyoming:"
	@echo "  go run ./cmd/wyoming-info --uri tcp://<pinevoice-ip>:10700   # expect mic 16000/2/1"
	@echo "  Then connect a client, send run-satellite, and confirm continuous"
	@echo "  audio-chunk events arrive without speaking a wake word."

# ---- Clean ----------------------------------------------------------------

.PHONY: clean
clean: clean-c906 clean-e907 ## Clean both solutions' build trees

.PHONY: clean-c906
clean-c906: ## Clean the C906 build tree
	cd $(C906_DIR) && ./go clean

.PHONY: clean-e907
clean-e907: ## Clean the E907 build tree
	cd $(E907_DIR) && ./go clean

# ---- Help -----------------------------------------------------------------

.PHONY: help
help: ## Print available targets
	@echo "PineVoice always-stream build & flash"
	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  %-22s %s\n", $$1, $$2}'
	@echo
	@echo "Typical flow (build in container, flash on host):"
	@echo "  make build      # first time (both cores)"
	@echo "  make build-fast # after editing wyoming.c"
	@echo "  make flash      # board in download mode, run on the host"
