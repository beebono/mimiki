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
SDL12_INSTALL="$BUILD_DIR/sdl12-install"

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
    for tool in make pkg-config ninja; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    # Check for SDL2 build
    if [ ! -d "$SDL2_INSTALL/usr/lib" ]; then
        print_error "SDL2 not found at $SDL2_INSTALL"
        print_error "Run build-tools.sh first to build SDL2"
        exit 1
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi

    print_step "All dependencies found!"
}

setup_sdl_environment() {
    print_step "Configuring SDL2 environment for cross-compilation..."

    # Point pkg-config to custom SDL2
    export PKG_CONFIG_PATH="$SDL2_INSTALL/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
    export PKG_CONFIG_LIBDIR="/usr/lib/aarch64-linux-gnu/pkgconfig"

    # Also set SDL2_CONFIG as fallback
    export SDL2_CONFIG="$SDL2_INSTALL/usr/bin/sdl2-config"

    # And set SDL_CONFIG so pcsx-rearmed can pick up sdl12-compat instead
    export SDL_CONFIG="$SDL12_INSTALL/usr/bin/sdl-config"

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
    apply_patches "yabasanshiro" "$EMU_DIR/yabasanshiro" "yabasanshiro"
    apply_patches "flycast" "$EMU_DIR/flycast" "flycast"
    apply_patches "ppsspp" "$EMU_DIR/ppsspp" "ppsspp"
    apply_patches "pcsx-rearmed" "$EMU_DIR/pcsx-rearmed" "pcsx-rearmed"
}

build_yabasanshiro() {
    print_step "Building YabaSanshiro..."

    local YABA_DIR="$EMU_DIR/yabasanshiro"
    local YABA_BUILD="$YABA_DIR/build"
    local YABA_INSTALL="$EMU_INSTALL/yabasanshiro"

    # Copy custom KMS/DRM port into source tree
    cp -r "$REPO_ROOT/system/ports/yabasanshiro/kmsdrm/" \
        "$YABA_DIR/yabause/src/"

    mkdir -p "$YABA_BUILD"
    cd "$YABA_BUILD"

    cmake ../yabause \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" -DCMAKE_BUILD_TYPE=Release \
        -DYAB_PORTS=kmsdrm -DYAB_WANT_VULKAN=ON -DYAB_WANT_SDL=ON \
        -DYAB_WANT_OPENAL=OFF -DYAB_WANT_OPENGL=ON -DUSE_EGL=ON \
        -DYAB_WANT_DYNAREC_DEVMIYAX=ON -DYAB_WANT_C68K=ON -DUSE_VK_KHR_DISPLAY=ON

    cmake --build . -j"$JOBS"

    if [ ! -f "$YABA_BUILD/src/kmsdrm/yabasanshiro" ]; then
        print_error "YabaSanshiro build failed!"
        exit 1
    fi

    "${CROSS_COMPILE}"strip --strip-unneeded "$YABA_BUILD/src/kmsdrm/yabasanshiro"

    mkdir -p "$YABA_INSTALL/bin"
    cp "$YABA_BUILD/src/kmsdrm/yabasanshiro" "$YABA_INSTALL/bin/"

    print_step "YabaSanshiro built and installed to $YABA_INSTALL"
}

build_flycast() {
    print_step "Building Flycast..."

    local FLYCAST_DIR="$EMU_DIR/flycast"
    local FLYCAST_BUILD="$FLYCAST_DIR/build"
    local FLYCAST_INSTALL="$EMU_INSTALL/flycast"

    mkdir -p "$FLYCAST_BUILD"
    cd "$FLYCAST_BUILD"

    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$FLYCAST_INSTALL" \
        -DUSE_VULKAN=ON -DUSE_HOST_SDL=ON -DUSE_OPENGL=OFF -DUSE_GLES=OFF \
        -DUSE_HOST_LIBZIP=OFF -DUSE_LIBAO=OFF -DUSE_PULSEAUDIO=OFF -DUSE_LUA=OFF \
        -DUSE_BREAKPAD=OFF -DWITH_LZMA_ASM=OFF -DUSE_DX9=OFF -DUSE_DX11=OFF -DDISABLE_CURL=ON 

    cmake --build . -j"$JOBS"

    if [ ! -f "$FLYCAST_BUILD/flycast" ]; then
        print_error "Flycast build failed!"
        exit 1
    fi

    "${CROSS_COMPILE}"strip --strip-unneeded "$FLYCAST_BUILD/flycast"
    cmake --install .

    print_step "Flycast built and installed to $FLYCAST_INSTALL"
}

build_pcsx() {
    print_step "Building PCSX-ReARMed..."

    local PCSX_DIR="$EMU_DIR/pcsx-rearmed"
    local PCSX_INSTALL="$EMU_INSTALL/pcsx"

    cd "$PCSX_DIR"

    CROSS_COMPILE="$CROSS_COMPILE" \
    CFLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" LDFLAGS="-flto=auto" \
    ./configure --dynarec=ari64 --gpu=neon --sound-drivers=sdl \
        --enable-neon --enable-threads --enable-dynamic 

    make -j"$JOBS"

    if [ ! -f "$PCSX_DIR/pcsx" ]; then
        print_error "PCSX-ReARMed build failed!"
        exit 1
    fi

    "${CROSS_COMPILE}"strip --strip-unneeded "$PCSX_DIR/pcsx"

    mkdir -p "$PCSX_INSTALL/bin"
    cp "$PCSX_DIR/pcsx" "$PCSX_INSTALL/bin/"

    print_step "PCSX-ReARMed built and installed to $PCSX_INSTALL"
}

build_ppsspp() {
    print_step "Building PPSSPP..."

    local PPSSPP_DIR="$EMU_DIR/ppsspp"
    local PPSSPP_BUILD="$PPSSPP_DIR/build"
    local PPSSPP_INSTALL="$EMU_INSTALL/ppsspp"

    mkdir -p "$PPSSPP_BUILD"
    cd "$PPSSPP_BUILD"

    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PPSSPP_INSTALL" \
        -DARM64=ON -DUSING_GLES2=ON -DUSE_FFMPEG=ON -DUSE_DISCORD=OFF -DUSE_MINIUPNPC=OFF \
        -DUSE_SYSTEM_SNAPPY=OFF -DUSE_SYSTEM_FFMPEG=OFF -DUSE_SYSTEM_LIBZIP=OFF \
        -DUSE_SYSTEM_ZSTD=OFF -DUSE_SYSTEM_MINIUPNPC=OFF -DUSING_QT_UI=OFF \
        -DUSING_X11_VULKAN=OFF -DUSE_WAYLAND_WSI=OFF -DUSE_VULKAN_DISPLAY_KHR=ON -DHEADLESS=OFF

    cmake --build . -j"$JOBS"

    if [ ! -f "$PPSSPP_BUILD/PPSSPPSDL" ]; then
        print_error "PPSSPP build failed!"
        exit 1
    fi

    "${CROSS_COMPILE}"strip --strip-unneeded "$PPSSPP_BUILD/PPSSPPSDL"

    mkdir -p "$PPSSPP_INSTALL/bin"
    cp "$PPSSPP_BUILD/PPSSPPSDL" "$PPSSPP_INSTALL/bin/"
    cp -r "$PPSSPP_DIR/assets" "$PPSSPP_INSTALL/"

    print_step "PPSSPP built and installed to $PPSSPP_INSTALL"
}

main() {
    echo -e "${GREEN}MIMIKI Emulator Builds${NC}"
    echo ""

    check_dependencies
    setup_sdl_environment
    apply_all_patches

    # Multiple compilations required for mupen64plus, use separate script
    "$SCRIPTS_DIR/build-mupen64plus.sh"
    build_yabasanshiro
    build_flycast
    build_pcsx
    build_ppsspp

    echo ""
    echo -e "${GREEN}MIMIKI Emulator Builds Complete!${NC}"
    echo ""
    echo "Installation directory: $EMU_INSTALL"
    echo "  N64:      $EMU_INSTALL/mupen64plus"
    echo "  DC:       $EMU_INSTALL/flycast"
    echo "  PS1:      $EMU_INSTALL/pcsx"
    echo "  PSP:      $EMU_INSTALL/ppsspp"
    echo "  Saturn:   $EMU_INSTALL/yabasanshiro"
}

main "$@"
