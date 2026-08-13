#!/bin/bash
# MIROKI - Launcher Build Script
# Cross-compiles the ncurses launcher for aarch64
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
LAUNCHER_DIR="$REPO_ROOT/system/launcher"

# Cross-compilation
CROSS_COMPILE=aarch64-linux-gnu-

print_step() {
    echo -e "${GREEN}==>${NC} $1" >&2
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1" >&2
}

check_dependencies() {
    print_step "Checking dependencies..."

    local missing_deps=()

    if ! command -v ${CROSS_COMPILE}gcc &> /dev/null; then
        missing_deps+=("${CROSS_COMPILE}gcc")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi

    print_step "All dependencies found!"
}

build_launcher() {
    print_step "Building Launcher..."

    cd "$LAUNCHER_DIR"
    make

    print_step "Launcher built!"
}

build_aggregator() {
    print_step "Building Input Aggregator..."

    cd "$REPO_ROOT/system/aggregator"
    make

    print_step "Input Aggregator built!"
}

build_glinfo() {
    print_step "Building GL Info (debug tool)..."

    cd "$REPO_ROOT/system/glinfo"
    make

    print_step "GL Info built!"
}

main() {
    print_step "MIROKI Launcher Build"

    check_dependencies
    build_launcher
    build_aggregator
    build_glinfo

    print_step "MIROKI Launcher Build Complete!"
}

main "$@"
