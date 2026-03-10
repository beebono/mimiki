#!/bin/bash
# MIMIKI - Emulators Build Script
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTERNAL_DIR="$REPO_ROOT/external"
BUILD_DIR="$REPO_ROOT/build"
EMU_DIR="$EXTERNAL_DIR/emulators"
EMU_INSTALL="$BUILD_DIR/emulators"
SDL2_INSTALL="$BUILD_DIR/sdl2-install"

# Cross-compilation
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
CMAKE_TC="$REPO_ROOT/system/config/toolchain-aarch64-linux-gnu.cmake"
HOST=aarch64-linux-gnu
JOBS=$(nproc)

print_step() {
    echo -e "${GREEN}==>${NC} $1" >&2
}

print_error() {
    echo -e "${RED}Error:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1" >&2
}

check_dependencies() {
    print_step "Checking dependencies..."

    local missing_deps=()

    # Cross-compiler
    if ! command -v "${CROSS_COMPILE}"gcc &> /dev/null; then
        missing_deps+=("${CROSS_COMPILE}gcc (aarch64 cross-compiler)")
    fi

    if ! command -v "${CROSS_COMPILE}"g++ &> /dev/null; then
        missing_deps+=("${CROSS_COMPILE}g++ (aarch64 cross-compiler)")
    fi

    # Build tools
    for tool in make pkg-config; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    # Check for SDL2 build
    if [ ! -d "$SDL2_INSTALL/usr/lib" ]; then
        print_error "SDL2 not found at $SDL2_INSTALL"
        print_error "Run build-launcher.sh first to build SDL2"
        exit 1
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi

    print_step "All dependencies found!"
}

setup_sdl2_environment() {
    print_step "Configuring SDL2 environment for cross-compilation..."

    # Point pkg-config to our custom SDL2
    export PKG_CONFIG_PATH="$SDL2_INSTALL/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    export PKG_CONFIG_SYSROOT_DIR="$SDL2_INSTALL"
    export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig"

    # Also set SDL2_CONFIG as fallback
    export SDL2_CONFIG="$SDL2_INSTALL/usr/bin/sdl2-config"

    # Override pkg-config to use cross-compile prefix if available
    if command -v "${CROSS_COMPILE}"pkg-config &> /dev/null; then
        export PKG_CONFIG="${CROSS_COMPILE}pkg-config"
    fi

    # Verify SDL2 is detected
    if ! pkg-config --exists sdl2; then
        print_error "SDL2 pkg-config file not found!"
        print_error "Expected at: $SDL2_INSTALL/usr/lib/pkgconfig/sdl2.pc"
        exit 1
    fi

    local sdl2_version=$(pkg-config --modversion sdl2)
    print_step "Found SDL2 version: $sdl2_version"
}

apply_patches() {
    local component_name="$1"
    local target_dir="$2"
    local patch_subdir="$3"

    print_step "Applying $component_name patches..."

    local PATCHES_DIR="$REPO_ROOT/system/patches/emulators/$patch_subdir"

    cd "$target_dir"

    if [ ! -d "$PATCHES_DIR" ] || [ -z "$(ls -A $PATCHES_DIR/*.patch 2>/dev/null)" ]; then
        print_warning "No $component_name patches found, skipping..."
        return
    fi

    if [ -f ".patches_applied" ]; then
        print_step "$component_name patches already applied, skipping..."
        return
    fi

    for patch in "$PATCHES_DIR"/*.patch; do
        if [ -f "$patch" ]; then
            local patch_name=$(basename "$patch")
            print_step "  Applying $patch_name..."
            git apply "$patch"
        fi
    done

    touch .patches_applied

    print_step "$component_name patches applied successfully!"
}

apply_all_patches() {
    apply_patches "mupen64plus" "$EMU_DIR/mupen64plus/video-gliden64" "mupen64plus"
    # Leave in case other patches are needed, otherwise consolidate before release
}

build_flycast() {

}

build_duckstation() {

}

build_ppsspp() {

}

main() {
    echo -e "${GREEN}MIMIKI Emulator Builds${NC}"
    echo ""

    check_dependencies
    setup_sdl2_environment
    apply_all_patches

    # Multiple compilations required for mupen64plus, use separate script
    "$SCRIPTS_DIR/build-mupen64plus.sh"
    build_flycast
    build_duckstation
    build_ppsspp

    echo ""
    echo -e "${GREEN}MIMIKI Emulator Builds Complete!${NC}"
    echo ""
    echo "Installation directory: $EMU_INSTALL"
    echo "  N64:      $EMU_INSTALL/mupen64plus"
    echo "  DC:       $EMU_INSTALL/flycast"
    echo "  PS1:      $EMU_INSTALL/duckstation"
    echo "  PSP:      $EMU_INSTALL/ppsspp"
}

main "$@"
