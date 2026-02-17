#!/bin/bash
# MIMIKI - Mupen64plus Build Script
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTERNAL_DIR="$REPO_ROOT/external"
M64P_DIR="$EXTERNAL_DIR/emulators/mupen64plus"
BUILD_DIR="$REPO_ROOT/build"
M64P_INSTALL="$BUILD_DIR/emulators/mupen64plus"
SDL2_INSTALL="$BUILD_DIR/sdl2-install"

# Cross-compilation
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
CMAKE_TC="$REPO_ROOT/system/config/toolchain-aarch64-linux-gnu.cmake"
HOST=aarch64-linux-gnu
JOBS=$(nproc)

# Component directories
CORE_DIR="$M64P_DIR/core"
API_DIR="$CORE_DIR/src/api"
AUDIO_SDL_DIR="$M64P_DIR/audio-sdl"
INPUT_SDL_DIR="$M64P_DIR/input-sdl"
RSP_HLE_DIR="$M64P_DIR/rsp-hle"
VIDEO_GLIDEN64_DIR="$M64P_DIR/video-gliden64"
UI_CONSOLE_DIR="$M64P_DIR/ui-console"

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

    # Create installation directories
    mkdir -p "$M64P_INSTALL/bin"
    mkdir -p "$M64P_INSTALL/lib/plugins"
}

build_core() {
    print_step "Building mupen64plus core library..."

    cd "$CORE_DIR/projects/unix"

    # Build configuration for ARM64
    make -j${JOBS} \
        all \
        HOST_CPU=aarch64 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PKG_CONFIG="${PKG_CONFIG}" \
        APIDIR="${API_DIR}" \
        OPTFLAGS="-Ofast -flto=auto" \
        NEON=1 \
        VFP_HARD=1 \
        USE_GLES=1 \
        VULKAN=0 \
        OSD=0 \
        NETPLAY=0 \
        NEW_DYNAREC=1 \
        PIC=1 \
        PREFIX=/usr

    if [ ! -f "$CORE_DIR/projects/unix/libmupen64plus.so.2.0.0" ]; then
        print_error "Core library build failed!"
        exit 1
    fi

    print_step "Core library built successfully!"
}

build_audio_sdl() {
    print_step "Building audio-sdl plugin..."

    cd "$AUDIO_SDL_DIR/projects/unix"

    make -j${JOBS} \
        all \
        HOST_CPU=aarch64 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PKG_CONFIG="${PKG_CONFIG}" \
        APIDIR="${API_DIR}" \
        OPTFLAGS="-Ofast -flto=auto" \
        PIC=1 \
        NO_SRC=1 \
        NO_SPEEX=1 \
        NO_OSS=1 \
        PREFIX=/usr

    if [ ! -f "$AUDIO_SDL_DIR/projects/unix/mupen64plus-audio-sdl.so" ]; then
        print_error "Audio plugin build failed!"
        exit 1
    fi

    print_step "Audio plugin built successfully!"
}

build_input_sdl() {
    print_step "Building input-sdl plugin..."

    cd "$INPUT_SDL_DIR/projects/unix"

    make -j${JOBS} \
        all \
        HOST_CPU=aarch64 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PKG_CONFIG="${PKG_CONFIG}" \
        APIDIR="${API_DIR}" \
        OPTFLAGS="-Ofast -flto=auto" \
        PIC=1 \
        PREFIX=/usr

    if [ ! -f "$INPUT_SDL_DIR/projects/unix/mupen64plus-input-sdl.so" ]; then
        print_error "Input plugin build failed!"
        exit 1
    fi

    print_step "Input plugin built successfully!"
}

build_rsp_hle() {
    print_step "Building rsp-hle plugin..."

    cd "$RSP_HLE_DIR/projects/unix"

    make -j${JOBS} \
        all \
        HOST_CPU=aarch64 \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        PKG_CONFIG="${PKG_CONFIG}" \
        APIDIR="${API_DIR}" \
        OPTFLAGS="-Ofast -flto=auto" \
        PIC=1 \
        PREFIX=/usr

    if [ ! -f "$RSP_HLE_DIR/projects/unix/mupen64plus-rsp-hle.so" ]; then
        print_error "RSP HLE plugin build failed!"
        exit 1
    fi

    print_step "RSP HLE plugin built successfully!"
}

build_video_gliden64() {
    print_step "Building video-gliden64..."

    cd "$VIDEO_GLIDEN64_DIR"
    mkdir -p build
    cd build
    cmake ../src \
        -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TC}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        -DCMAKE_CXX_FLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        -DEGL=ON -DMUPENPLUSAPI=ON -DMESA=ON -DNO_OSD=ON -DNOHQ=ON -DVEC4_OPT=ON -DCRC_OPT=ON \
        -DNEON_OPT=ON -DUNIX=ON
    make -j${JOBS}

    if [ ! -f "$VIDEO_GLIDEN64_DIR/build/plugin/Release/mupen64plus-video-GLideN64.so" ]; then
        print_error "Video GLideN64 plugin build failed!"
        exit 1
    fi
}

build_ui_console() {
    print_step "Building ui-console frontend..."

    cd "$UI_CONSOLE_DIR/projects/unix"

    make -j${JOBS} \
        all \
        HOST_CPU=aarch64 \
        CROSS_COMPILE=${CROSS_COMPILE} \
        PKG_CONFIG="${PKG_CONFIG}" \
        APIDIR="${API_DIR}" \
        OPTFLAGS="-Ofast -flto=auto" \
        PIE=1 \
        PREFIX=/usr

    if [ ! -f "$UI_CONSOLE_DIR/projects/unix/mupen64plus" ]; then
        print_error "UI console build failed!"
        exit 1
    fi

    print_step "UI console built successfully!"
}

strip_binaries() {
    print_step "Stripping binaries to reduce size..."

    "${CROSS_COMPILE}"strip --strip-unneeded \
        "$CORE_DIR/projects/unix/libmupen64plus.so.2.0.0"
    "${CROSS_COMPILE}"strip --strip-unneeded \
        "$AUDIO_SDL_DIR/projects/unix/mupen64plus-audio-sdl.so"
    "${CROSS_COMPILE}"strip --strip-unneeded \
        "$INPUT_SDL_DIR/projects/unix/mupen64plus-input-sdl.so"
    "${CROSS_COMPILE}"strip --strip-unneeded \
        "$RSP_HLE_DIR/projects/unix/mupen64plus-rsp-hle.so"
    "${CROSS_COMPILE}"strip --strip-unneeded \
        "$VIDEO_GLIDEN64_DIR/build/plugin/Release/mupen64plus-video-GLideN64.so"
    "${CROSS_COMPILE}"strip --strip-unneeded \
        "$UI_CONSOLE_DIR/projects/unix/mupen64plus"

    print_step "Binaries stripped!"
}

install_mupen64plus() {
    print_step "Installing mupen64plus to build directory..."

    cp "$CORE_DIR/projects/unix/libmupen64plus.so.2.0.0" \
        "$M64P_INSTALL/lib/libmupen64plus.so.2"
    cp "$AUDIO_SDL_DIR/projects/unix/mupen64plus-audio-sdl.so" \
        "$M64P_INSTALL/lib/plugins/"
    cp "$INPUT_SDL_DIR/projects/unix/mupen64plus-input-sdl.so" \
        "$M64P_INSTALL/lib/plugins/"
    cp "$RSP_HLE_DIR/projects/unix/mupen64plus-rsp-hle.so" \
        "$M64P_INSTALL/lib/plugins/"
    cp "$VIDEO_GLIDEN64_DIR/build/plugin/Release/mupen64plus-video-GLideN64.so" \
        "$M64P_INSTALL/lib/plugins/"
    cp "$UI_CONSOLE_DIR/projects/unix/mupen64plus" \
       "$M64P_INSTALL/bin/"

    print_step "Mupen64plus installed to $M64P_INSTALL"
}

main() {
    echo -e "${GREEN}MIMIKI Mupen64plus Build${NC}"
    echo ""

    check_dependencies
    setup_sdl2_environment
    build_core
    build_audio_sdl
    build_input_sdl
    build_rsp_hle
    build_video_gliden64
    build_ui_console
    strip_binaries
    install_mupen64plus

    echo ""
    echo -e "${GREEN}MIMIKI Mupen64plus Build Complete!${NC}"
    echo ""
    echo "Installation directory: $M64P_INSTALL"
    echo "  Core library:    build/emulators/lib/libmupen64plus.so.2.0.0"
    echo "  Plugins:         build/emulators/lib/mupen64plus/*.so"
    echo "  Executable:      build/emulators/mupen64plus/bin/mupen64plus"
}

main "$@"
