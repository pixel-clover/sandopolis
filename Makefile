################################################################################
# Configuration and Variables
################################################################################
ZIG           ?= $(shell which zig || echo ~/.local/share/zig/0.15.2/zig)
ZIG_VERSION   := $(shell $(ZIG) version)
BUILD_TYPE    ?= ReleaseSafe
BUILD_OPTS      = -Doptimize=$(BUILD_TYPE)
JOBS          ?= $(shell nproc || echo 2)
SRC_DIR       := src
TEST_DIR      := tests
BUILD_DIR     := zig-out
CACHE_DIR     := .zig-cache
DOC_OUT       := docs/api/
SITE_DIR      := site
BINARY_NAME   := sandopolis
BINARY_PATH   := $(BUILD_DIR)/bin/$(BINARY_NAME)
PREFIX        ?= /usr/local
RELEASE_MODE := ReleaseSmall
TMP_DIRS	  := .zig-cache .zig-cache-unit .zig-global-cache
ARGS          ?=
UV            ?= $(shell which uv || echo ~/.local/bin/uv)

SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eu -o pipefail -c

################################################################################
# Targets
################################################################################

.PHONY: all build rebuild run test test-unit test-integration test-regression test-property lint format docs docs-serve clean \
 install-deps release help setup-hooks test-hooks wasm web web-serve
.DEFAULT_GOAL := help

help: ## Show the help messages for all targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

all: build test lint docs  ## build, test, lint, and doc

build: ## Build project (default Mode=$(BUILD_TYPE); override with e.g. `BUILD_TYPE=Debug`)
	@echo "Building project in $(BUILD_TYPE) mode with $(JOBS) concurrent jobs..."
	$(ZIG) build $(BUILD_OPTS) -j$(JOBS)

rebuild: clean build  ## clean and build

run: build  ## Run the main application
	@echo "Running $(BINARY_NAME)..."
	$(ZIG) build run $(BUILD_OPTS) -- $(ARGS)

test: ## Run all test suites
	@echo "Running all test suites..."
	$(ZIG) build test $(BUILD_OPTS) -j$(JOBS)

test-unit: ## Run unit tests
	$(ZIG) build test-unit $(BUILD_OPTS) -j$(JOBS)

test-integration: ## Run integration tests
	$(ZIG) build test-integration $(BUILD_OPTS) -j$(JOBS)

test-regression: ## Run regression tests
	$(ZIG) build test-regression $(BUILD_OPTS) -j$(JOBS)

test-property: ## Run property-based tests
	$(ZIG) build test-property $(BUILD_OPTS) -j$(JOBS)

release: ## Build in Release mode
	@echo "Building the project in Release mode..."
	@$(MAKE) BUILD_TYPE=$(RELEASE_MODE) build

clean: ## Remove docs output, build artifacts, and cache directories
	@echo "Removing build artifacts, cache, and generated docs..."
	rm -rf $(BUILD_DIR) $(CACHE_DIR) $(DOC_OUT) $(SITE_DIR) $(TMP_DIRS)

lint: ## Check code style and formatting of Zig files
	@echo "Running code style checks..."
	$(ZIG) fmt --check .

format: ## Format Zig files
	@echo "Formatting Zig files..."
	$(ZIG) fmt .

docs: ## Generate Zig API docs and build the MkDocs site
	@echo "Generating Zig API documentation into $(DOC_OUT)..."
	$(ZIG) build docs $(BUILD_OPTS) --prefix . -j$(JOBS)
	@echo "Building MkDocs site into $(SITE_DIR)..."
	$(UV) run mkdocs build --strict

docs-serve: ## Regenerate Zig API docs and serve the MkDocs site locally
	@echo "Generating Zig API documentation into $(DOC_OUT)..."
	$(ZIG) build docs $(BUILD_OPTS) --prefix . -j$(JOBS)
	@echo "Starting MkDocs dev server..."
	$(UV) run mkdocs serve

wasm: ## Build the WebAssembly module
	@echo "Building WebAssembly module..."
	$(ZIG) build wasm -j$(JOBS)

web: wasm ## Build WASM and assemble the web directory for deployment
	@echo "Assembling web deployment..."
	cp $(BUILD_DIR)/web/sandopolis.wasm web/sandopolis.wasm
	mkdir -p web/img
	cp docs/assets/overlays/crt/*.png docs/assets/overlays/genesis/*.png web/img/

web-serve: web ## Build and serve the web emulator locally
	@echo "Serving Sandopolis web emulator locally"
	cd web && python3 -m http.server 8000

install-deps: ## Install system dependencies (for Debian-based systems)
	@echo "Installing system dependencies..."
	sudo apt-get update
	sudo apt-get install -y make snapd
	sudo snap install zig  --beta --classic # Use `--edge --classic` to install the latest version

setup-hooks: ## Install Git hooks (pre-commit and pre-push)
	@echo "Installing Git hooks..."
	@pre-commit install --hook-type pre-commit
	@pre-commit install --hook-type pre-push
	@pre-commit install-hooks

test-hooks: ## Run Git hooks on all files manually
	@echo "Running Git hooks..."
	@pre-commit run --all-files
