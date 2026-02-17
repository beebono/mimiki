#!/bin/bash
# MIMIKI - SDL2 Build Script
# Cross-compiles a minimal SDL2 for KMS/DRM + Vulkan
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
SDL2_INSTALL="$BUILD_DIR/sdl2-install"

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

    if [ ! -d "$SDL2_INSTALL" ]; then
        print_error "SDL2 isn't built yet! Run 'make tools' first!"
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

install_launcher_assets() {
    print_step "Installing launcher assets..."

    mkdir -p "$SDL2_INSTALL/usr/share/mimiki/assets"

    if [ -f "$LAUNCHER_DIR/assets/font.png" ]; then
        cp "$LAUNCHER_DIR/assets/font.png" "$SDL2_INSTALL/usr/share/mimiki/assets/"
        print_step "Font atlas installed!"
    else
        print_warning "Font atlas not found. Reggie what did you do."
    fi
}

main() {
    print_step "MIMIKI Launcher Build"

    check_dependencies
    build_launcher
    install_launcher_assets

    print_step "MIMIKI Launcher Build Complete!"
}

main "$@"
