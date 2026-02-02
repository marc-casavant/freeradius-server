#
# all.mk for multi-server tests
#
# Create one make target per test YAML:
#
# For example:
#   test-5hs-autoaccept   -> uses test-5hs-autoaccept.yml
#   and compose becomes   -> environments/docker-compose/env-5hs-autoaccept.yml
#
# The compose file is selected by stripping "test-" prefix and adding "env-" prefix.
# The same compose file is used for all testcase variants (e.g. test-5hs-autoaccept-5min, test-5hs-autoaccept-variant3).

define MAKE_TEST_TARGET
.PHONY: $(1)
$(1): TEST_FILENAME  := $(1).yml
$(1): TEST_NAME := $(1)

$(1): ENV_COMPOSE_PATH = environments/docker-compose/$$(patsubst test-%,env-%,$$(basename $$(TEST_FILENAME))).yml

$(1): clone
	@echo "BUILD_DIR=$(BUILD_DIR)"
	@echo "MULTI_SERVER_DIR=$(MULTI_SERVER_DIR)"
	@mkdir -p "$(MULTI_SERVER_DIR)/freeradius-listener-logs/$$(TEST_NAME)"
	@cd "$(FRAMEWORK_REPO_DIR)" && \
		$(MAKE) configure && \
		. ".venv/bin/activate" && \
		echo "DEBUG: TEST_FILENAME=$$(TEST_FILENAME)" && \
		echo "DEBUG: TEST_NAME=$$(TEST_NAME)" && \
		echo "DEBUG: ENV_COMPOSE_PATH=$$(ENV_COMPOSE_PATH)" && \
		echo "DEBUG: ALL_MK_DIR=$(ALL_MK_DIR)" && \
			test -f "$(ALL_MK_DIR)$$(ENV_COMPOSE_PATH)" || { \
				echo "ERROR: Missing compose file: $(ALL_MK_DIR)$$(ENV_COMPOSE_PATH)"; \
			exit 1; \
		} && \
		DATA_PATH="$(ALL_MK_DIR)environments/configs"; \
		LISTENER_DIR="$(ALL_MK_DIR)$(MULTI_SERVER_DIR)/freeradius-listener-logs/$$(TEST_NAME)"; \
		echo "DEBUG: DATA_PATH=$$$$DATA_PATH"; \
		echo "DEBUG: LISTENER_DIR=$$$$LISTENER_DIR"; \
		CMD="DATA_PATH=$(ALL_MK_DIR)environments/configs make test-framework -- -x -v --compose $(ALL_MK_DIR)$$(ENV_COMPOSE_PATH) --test $(ALL_MK_DIR)$$(TEST_FILENAME) --use-files --listener-dir $$$$LISTENER_DIR"; \
		echo "DEBUG: CMD = $$$$CMD"; \
		bash -c "$$$$CMD"
endef

# Set directory name where all.mk is located. Help with relative paths.
ALL_MK_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Where we keep build-side artifacts for this test suite
MULTI_SERVER_DIR := $(BUILD_DIR)/tests/multi-server
VENV_DIR := $(MULTI_SERVER_DIR)/.venv

# Clone a repo into $(BUILD_DIR)/tests/multi-server/
FRAMEWORK_GIT_URL  ?= https://github.com/InkbridgeNetworks/freeradius-multi-server.git
FRAMEWORK_REPO_DIR ?= $(MULTI_SERVER_DIR)/freeradius-multi-server

CLONE_STAMP := $(FRAMEWORK_REPO_DIR)/.git/HEAD

.PHONY: clone
clone: $(CLONE_STAMP)

$(CLONE_STAMP): | $(MULTI_SERVER_DIR)
	@if [ -d "$(FRAMEWORK_REPO_DIR)/.git" ]; then \
		echo "Repo already cloned: $(FRAMEWORK_REPO_DIR)"; \
	else \
		git clone "$(FRAMEWORK_GIT_URL)" "$(FRAMEWORK_REPO_DIR)"; \
	fi
	@# Ensure the stamp exists even if git changes behavior
	@test -f "$@" || { echo "ERROR: clone stamp missing: $@"; exit 1; }

# Per-target variable (set by the generated targets below)
TEST_FILENAME ?=

# Discover available tests (files like test-*.yml in this directory)
TEST_YMLS  := $(notdir $(wildcard $(ALL_MK_DIR)test-*.yml))
TEST_NAMES := $(basename $(TEST_YMLS))

# Instantiate dynamic test targets for each discovered test YAML
ifndef MULTI_SERVER_TEST_TARGETS_DEFINED
MULTI_SERVER_TEST_TARGETS_DEFINED := 1
$(foreach test,$(TEST_NAMES),$(info Found test: $(test))$(eval $(call MAKE_TEST_TARGET,$(test))))
endif

all: $(TEST_NAMES)

# Ensure the target directory exists
$(MULTI_SERVER_DIR):
	@mkdir -p "$@"

# Create .venv if it doesn't exist (in the build directory)
$(VENV_DIR): | $(MULTI_SERVER_DIR)
	python3 -m venv "$(VENV_DIR)"

venv: $(VENV_DIR)
