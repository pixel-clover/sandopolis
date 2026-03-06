################################################################################
# Configuration and Variables
################################################################################
ZIG           ?= zig
ZIG_VERSION   := $(shell $(ZIG) version)
BUILD_TYPE    ?= Debug
BUILD_OPTS      = -Doptimize=$(BUILD_TYPE)
JOBS          ?= $(shell nproc || echo 2)
SRC_DIR       := src
TEST_DIR      := tests
BUILD_DIR     := zig-out
CACHE_DIR     := .zig-cache
DOC_OUT       := docs/api/
BINARY_NAME   := sandopolis
BINARY_PATH   := $(BUILD_DIR)/bin/$(BINARY_NAME)
PREFIX        ?= /usr/local
RELEASE_MODE := ReleaseSmall
ARGS          ?=

SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eu -o pipefail -c

################################################################################
# Targets
################################################################################

.PHONY: all build rebuild run test test-unit test-integration test-regression test-property lint format docs clean install-deps release help setup-hooks test-hooks
.DEFAULT_GOAL := help

help: ## Show the help messages for all targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-10s %s\n", $$1, $$2}'

all: build test lint docs  ## build, test, lint, and doc

build: ## Build project (Mode=$(BUILD_TYPE) like `Debug` or `ReleaseFast`)
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

clean: ## Remove docs, build artifacts, and cache directories
	@echo "Removing build artifacts, cache, and generated docs..."
	rm -rf $(BUILD_DIR) $(CACHE_DIR) $(DOC_OUT)

lint: ## Check code style and formatting of Zig files
	@echo "Running code style checks..."
	$(ZIG) fmt --check .

format: ## Format Zig files
	@echo "Formatting Zig files..."
	$(ZIG) fmt .

docs: ## Generate API documentation
	@echo "Generating API documentation into $(DOC_OUT)..."
	$(ZIG) build docs $(BUILD_OPTS) --prefix . -j$(JOBS)

install-deps: ## Install system dependencies (for Debian-based systems)
	@echo "Installing system dependencies..."
	sudo apt-get update
	sudo apt-get install -y make llvm snapd
	sudo snap install zig  --beta --classic # Use `--edge --classic` to install the latest version

setup-hooks: ## Install Git hooks (pre-commit and pre-push)
	@echo "Installing Git hooks..."
	@pre-commit install --hook-type pre-commit
	@pre-commit install --hook-type pre-push
	@pre-commit install-hooks

test-hooks: ## Run Git hooks on all files manually
	@echo "Running Git hooks..."
	@pre-commit run --all-files
