################################################################################
# all.mk - Multi-Server Test Framework
################################################################################

################################################################################
# 1. OVERVIEW
################################################################################
#
# This Makefile dynamically generates test targets from test-*.yml files.
# Multiple test variants can share the same Docker Compose environment.
#
# EXAMPLES:
#
#   make test-5hs-autoaccept
#     -> TEST_FILENAME     = test-5hs-autoaccept.yml
#     -> ENV_COMPOSE_PATH  = environments/docker-compose/env-5hs-autoaccept.yml
#
#   make test-5hs-autoaccept-5min
#     -> TEST_FILENAME     = test-5hs-autoaccept-5min.yml
#     -> ENV_COMPOSE_PATH  = environments/docker-compose/env-5hs-autoaccept.yml
#
#   make test-2p-2p-4hs-sql-mycustomvariantstring
#     -> TEST_FILENAME     = test-2p-2p-4hs-sql-mycustomvariantstring.yml
#     -> ENV_COMPOSE_PATH  = environments/docker-compose/env-2p-2p-4hs-sql.yml
#
################################################################################

################################################################################
# 2. DIRECTORY & PATH CONFIGURATION
################################################################################

# Base directory: location of this Makefile
MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Build directory - use 'build' if not set by parent Makefile
# This allows the file to work both standalone and as part of a larger build
ifeq ($(origin BUILD_DIR), undefined)
BUILD_DIR := build
endif

# FreeRADIUS build artifacts location
FREERADIUS_SERVER_BUILD_DIR_REL_PATH := $(BUILD_DIR)

# Multi-server test artifacts location
MULTI_SERVER_BUILD_DIR_REL_PATH := $(FREERADIUS_SERVER_BUILD_DIR_REL_PATH)/tests/multi-server
MULTI_SERVER_BUILD_DIR_ABS_PATH := $(abspath $(MULTI_SERVER_BUILD_DIR_REL_PATH))
VENV_DIR := $(MULTI_SERVER_BUILD_DIR_REL_PATH)/.venv

################################################################################
# 3. FRAMEWORK REPOSITORY SETUP
################################################################################

# Git repository containing the multi-server test framework
FRAMEWORK_GIT_URL  ?= https://github.com/InkbridgeNetworks/freeradius-multi-server.git
FRAMEWORK_REPO_DIR ?= $(MULTI_SERVER_BUILD_DIR_REL_PATH)/freeradius-multi-server

# Stamp file to track if repo has been cloned
CLONE_STAMP := $(FRAMEWORK_REPO_DIR)/.git/HEAD

# Clone the test framework repository if not already present
.PHONY: clone
clone: $(CLONE_STAMP)

$(CLONE_STAMP): | $(MULTI_SERVER_BUILD_DIR_REL_PATH)
	@if [ -d "$(FRAMEWORK_REPO_DIR)/.git" ]; then \
		echo "Repo already cloned: $(FRAMEWORK_REPO_DIR)"; \
	else \
		git clone "$(FRAMEWORK_GIT_URL)" "$(FRAMEWORK_REPO_DIR)"; \
	fi
	@# Ensure the stamp exists even if git changes behavior
	@test -f "$@" || { echo "ERROR: clone stamp missing: $@"; exit 1; }

# Ensure build directory exists
$(MULTI_SERVER_BUILD_DIR_REL_PATH):
	@mkdir -p "$@"

################################################################################
# 4. HELPER FUNCTIONS
################################################################################

# FIND_ENV_COMPOSE_J2 - Locate the test's environment Docker compose template
#
# For example, for a test name "test-5hs-autoaccept-5min", this function strips
# trailing hyphenated segments until it finds a matching environment file.
#
# Returns: Path to the .j2 template relative to MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH
#
define FIND_ENV_COMPOSE_J2
$(strip $(shell \
	name='$(1)'; \
	base="$$name"; \
	while :; do \
		env="environments/docker-compose/env-$${base#test-}.yml"; \
		envj2="$$env.j2"; \
		if [ -f "$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)$$envj2" ]; then \
			printf '%s' "$$envj2"; \
			exit 0; \
		fi; \
		newbase="$${base%-*}"; \
		if [ "$$newbase" = "$$base" ]; then \
			echo "ERROR: No matching env compose template for $(1) (expected $$env.j2 and shorter prefixes)" 1>&2; \
			exit 1; \
		fi; \
		base="$$newbase"; \
	done))
endef

################################################################################
# 5. DYNAMIC TEST TARGET GENERATION
################################################################################

# MAKE_TEST_TARGET - Generate a complete test target
#
# This function creates a Make target for each test file. The target:
#   1. Sets up per-target variables (test name, paths, etc.)
#   2. Finds the matching environment Compose template
#   3. Renders Jinja2 templates (configs + docker-compose file)
#   4. Runs the test framework with the rendered files
#
# Parameter: $(1) = test name (e.g., "test-5hs-autoaccept")
#
define MAKE_TEST_TARGET
.PHONY: $(1)

# ---- Per-Target Variable Setup ----
$(1): TEST_NAME     := $(1)
$(1): TEST_FILENAME := $$(TEST_NAME).yml

# Find which environment Compose template to use
$(1): ENV_COMPOSE_TEMPLATE_PATH := $$(call FIND_ENV_COMPOSE_J2,$$(TEST_NAME))

# Output Compose file path (strip .j2 extension)
$(1): ENV_COMPOSE_PATH := $$(patsubst %.j2,%,$$(ENV_COMPOSE_TEMPLATE_PATH))

# Extract environment stem from path
# Example: environments/docker-compose/env-5hs-autoaccept.yml -> 5hs-autoaccept
$(1): ENV_STEM := $$(patsubst environments/docker-compose/env-%.yml,%,$$(ENV_COMPOSE_PATH))

# Jinja2 variables file
$(1): VARS_FILE_REL ?= environments/jinja-vars/env-$$(ENV_STEM).vars.yml

$(1): clone
	@echo "MULTI_SERVER_BUILD_DIR_REL_PATH=$(MULTI_SERVER_BUILD_DIR_REL_PATH)"
	@echo "MULTI_SERVER_BUILD_DIR_ABS_PATH=$(MULTI_SERVER_BUILD_DIR_ABS_PATH)"
	@echo "TARGET_TEST_NAME=$(1)"
	@echo "TARGET_TEST_FILENAME=$$(TEST_FILENAME)"
	@echo "TARGET_VARS_FILE_REL=$$(VARS_FILE_REL)"
	@echo "TARGET_ENV_COMPOSE_TEMPLATE_PATH=$$(ENV_COMPOSE_TEMPLATE_PATH)"
	@echo "TARGET_ENV_COMPOSE_PATH=$$(ENV_COMPOSE_PATH)"
	@mkdir -p "$(MULTI_SERVER_BUILD_DIR_REL_PATH)/freeradius-listener-logs/$$(TEST_NAME)"
	@bash -lc 'set -euo pipefail; \
		\
		echo "==> [Step 1/7] Entering framework repo: $(FRAMEWORK_REPO_DIR)"; \
		cd "$(FRAMEWORK_REPO_DIR)" || { echo "ERROR: Failed to cd to $(FRAMEWORK_REPO_DIR)" >&2; exit 1; }; \
		\
		echo "==> [Step 2/7] Updating framework repository"; \
		git pull || { echo "ERROR: git pull failed" >&2; exit 1; }; \
		\
		echo "==> [Step 3/7] Configuring framework"; \
		$(MAKE) configure || { echo "ERROR: make configure failed" >&2; exit 1; }; \
		\
		echo "==> [Step 4/7] Activating Python virtual environment"; \
		. ".venv/bin/activate" || { echo "ERROR: Failed to activate venv" >&2; exit 1; }; \
		\
		echo "==> [Step 5/7] Building absolute paths"; \
		echo "  DEBUG: TEST_NAME = $(1)"; \
		echo "  DEBUG: VARS_FILE_REL = $$(VARS_FILE_REL)"; \
		echo "  DEBUG: ENV_COMPOSE_TEMPLATE_PATH = $$(ENV_COMPOSE_TEMPLATE_PATH)"; \
		echo "  DEBUG: BASE_DIR = $(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)"; \
		\
		DATA_PATH="$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)environments/configs"; \
		LISTENER_DIR="$(MULTI_SERVER_BUILD_DIR_ABS_PATH)/freeradius-listener-logs/$(1)"; \
		JINJA_RENDERER_INCLUDE_PATH="$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)"; \
		VARS_FILE_ABS="$$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)$$(VARS_FILE_REL)"; \
		ENV_COMPOSE_TEMPLATE_ABS="$$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)$$(ENV_COMPOSE_TEMPLATE_PATH)"; \
		ENV_COMPOSE_ABS="$$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)$$(ENV_COMPOSE_PATH)"; \
		TEST_FILENAME_ABS="$$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)$$(TEST_FILENAME)"; \
		\
		echo "  DEBUG: DATA_PATH = $$$$DATA_PATH"; \
		echo "  DEBUG: LISTENER_DIR = $$$$LISTENER_DIR"; \
		echo "  DEBUG: JINJA_RENDERER_INCLUDE_PATH = $$$$JINJA_RENDERER_INCLUDE_PATH"; \
		echo "  DEBUG: VARS_FILE_ABS = $$$$VARS_FILE_ABS"; \
		echo "  DEBUG: ENV_COMPOSE_TEMPLATE_ABS = $$$$ENV_COMPOSE_TEMPLATE_ABS"; \
		echo "  DEBUG: ENV_COMPOSE_ABS = $$$$ENV_COMPOSE_ABS"; \
		echo "  DEBUG: TEST_FILENAME_ABS = $$$$TEST_FILENAME_ABS"; \
		\
		echo "==> [Step 6/7] Validating required files"; \
		\
		test -f "$$$$VARS_FILE_ABS" || { \
			echo "ERROR: Missing vars file: $$$$VARS_FILE_ABS" >&2; exit 1; \
		}; \
		echo "  - Found vars file"; \
		test -f "$$$$ENV_COMPOSE_TEMPLATE_ABS" || { \
			echo "ERROR: Missing compose template: $$$$ENV_COMPOSE_TEMPLATE_ABS" >&2; exit 1; \
		}; \
		echo "  - Found compose template"; \
		test -f "$$$$TEST_FILENAME_ABS" || { \
			echo "ERROR: Missing test file: $$$$TEST_FILENAME_ABS" >&2; exit 1; \
		}; \
		echo "  - Found test file"; \
		echo ""; \
		\
		echo "==> [Step 7/7] Rendering Jinja2 templates and running tests"; \
		\
		echo "  - Reading jinja_templates_to_render from vars file"; \
		TEMPLATE_LIST_FILE=`mktemp`; \
		sed -n "/^jinja_templates_to_render:/,/^[A-Za-z0-9_].*:/p" "$$$$VARS_FILE_ABS" \
			| sed -n "s/^  - //p" > "$$$$TEMPLATE_LIST_FILE"; \
		\
		if [ -s "$$$$TEMPLATE_LIST_FILE" ]; then \
			echo "  - Templates to render:"; \
			while IFS= read -r rel_tmpl; do \
				[ -n "$$$$rel_tmpl" ] || continue; \
				echo "    - $$$$rel_tmpl"; \
			done < "$$$$TEMPLATE_LIST_FILE"; \
			echo ""; \
			while IFS= read -r rel_tmpl; do \
				[ -n "$$$$rel_tmpl" ] || continue; \
				aux_abs="$$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)$$$$rel_tmpl"; \
				output_abs="$$$$aux_abs"; output_abs="$$$${output_abs%.j2}"; \
				test -f "$$$$aux_abs" || { echo "ERROR: Template not found: $$$$aux_abs" >&2; exit 1; }; \
				if [ -d "$$$$output_abs" ]; then \
					if [ -z "$$(ls -A "$$$$output_abs")" ]; then \
						echo "  - Removing empty directory blocking output: $$$$output_abs"; \
						rmdir "$$$$output_abs"; \
					else \
						echo "ERROR: Output path is a non-empty directory: $$$$output_abs" >&2; exit 1; \
					fi; \
				fi; \
				echo "  - Rendering $$$$rel_tmpl"; \
				python3 src/config_builder.py \
					--vars-file "$$$$VARS_FILE_ABS" \
					--aux-file "$$$$aux_abs" \
					--include-path "$$$$JINJA_RENDERER_INCLUDE_PATH" || exit 1; \
			done < "$$$$TEMPLATE_LIST_FILE"; \
		else \
			echo "  ℹ No templates in jinja_templates_to_render list"; \
		fi; \
		rm -f "$$$$TEMPLATE_LIST_FILE"; \
		\
		test -f "$$$$ENV_COMPOSE_ABS" || { \
			echo "ERROR: Compose file was not generated: $$$$ENV_COMPOSE_ABS" >&2; exit 1; \
		}; \
		echo "  - Generated compose file"; \
		echo ""; \
		\
		echo "  - Running test-framework"; \
		DATA_PATH="$$(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)environments/configs" \
			make test-framework -- -x -v \
			--compose "$$$$ENV_COMPOSE_ABS" \
			--test "$$$$TEST_FILENAME_ABS" \
			--use-files \
			--listener-dir "$$$$LISTENER_DIR"'
endef

################################################################################
# 6. TEST DISCOVERY & INSTANTIATION
################################################################################

# Per-target variable (will be set by generated targets)
TEST_FILENAME ?=

# Discover all test-*.yml files in this directory
TEST_YMLS  := $(notdir $(wildcard $(MULTI_SERVER_TESTS_BASE_DIR_ABS_PATH)test-*.yml))
TEST_NAMES := $(basename $(TEST_YMLS))

# Generate a target for each discovered test (only once)
ifndef MULTI_SERVER_TEST_TARGETS_DEFINED
MULTI_SERVER_TEST_TARGETS_DEFINED := 1
$(foreach test,$(TEST_NAMES),$(info Found test: $(test))$(eval $(call MAKE_TEST_TARGET,$(test))))
endif

# Default target: run all discovered tests
all: $(TEST_NAMES)
