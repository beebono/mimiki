#!/bin/bash
# MIROKI - Emulators Build Script
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
            # The marker file can go missing while the tree stays patched
            # (live-debug edits, cleans); detect per patch instead of failing
            if git apply --reverse --check "$patch" 2>/dev/null; then
                print_step "  $patch_name already applied, skipping..."
            else
                print_step "  Applying $patch_name..."
                git apply "$patch"
            fi
        fi
    done

    touch .patches_applied

    print_step "$component_name patches applied successfully!"
}

apply_all_patches() {
    apply_patches "mupen64plus" "$EMU_DIR/mupen64plus/video-gliden64" "mupen64plus"
    apply_patches "yabasanshiro" "$EMU_DIR/yabasanshiro" "yabasanshiro"
    apply_patches "flycast" "$EMU_DIR/flycast" "flycast"
    apply_patches "pcsx-rearmed" "$EMU_DIR/pcsx-rearmed" "pcsx-rearmed"
    # libpicofe is a nested submodule of pcsx-rearmed - patch it separately
    apply_patches "libpicofe" "$EMU_DIR/pcsx-rearmed/frontend/libpicofe" "libpicofe"
    apply_patches "dolphin" "$EMU_DIR/dolphin" "dolphin"
    apply_patches "armsx2" "$EMU_DIR/armsx2" "armsx2"
}

build_dolphin() {
    print_step "Building Dolphin (NoGUI)..."

    local DOLPHIN_DIR="$EMU_DIR/dolphin"
    local DOLPHIN_BUILD="$DOLPHIN_DIR/build"
    local DOLPHIN_INSTALL="$EMU_INSTALL/dolphin"

    # VMA header include fixes needed for the Vulkan build under newer GCC
    grep -q '#include <cstdint>' "$DOLPHIN_DIR/Externals/VulkanMemoryAllocator/include/vk_mem_alloc.h" || \
        sed -i 's~#include <cstdlib>~#include <cstdlib>\n#include <cstdint>~' \
            "$DOLPHIN_DIR/Externals/VulkanMemoryAllocator/include/vk_mem_alloc.h"
    grep -q '#include <string>' "$DOLPHIN_DIR/Externals/VulkanMemoryAllocator/include/vk_mem_alloc.h" || \
        sed -i 's~#include <cstdint>~#include <cstdint>\n#include <string>~' \
            "$DOLPHIN_DIR/Externals/VulkanMemoryAllocator/include/vk_mem_alloc.h"

    mkdir -p "$DOLPHIN_BUILD"
    cd "$DOLPHIN_BUILD"

    # NoGUI-only, fbdev platform (this tree's default: no compositor needed,
    # EGL/GLES on the framebuffer). SDL3 comes bundled from Externals/SDL.
    # Vulkan is built in but not the runtime default: the backend has no
    # VK_KHR_display surface path yet, so fbdev launches use OGL(GLES) until a
    # display-surface patch lands; then flip GFXBackend = Vulkan in Dolphin.ini.
    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DOLPHIN_INSTALL" \
        -DENABLE_NOGUI=ON -DENABLE_QT=OFF \
        -DSDL_LIBUDEV=OFF \
        -DENABLE_EGL=ON -DENABLE_X11=OFF -DENABLE_WAYLAND=OFF \
        -DENABLE_VULKAN=ON \
        -DENABLE_EVDEV=ON -DENABLE_SDL=ON \
        -DENABLE_ALSA=ON -DENABLE_PULSEAUDIO=OFF \
        -DENABLE_ANALYTICS=OFF -DENABLE_AUTOUPDATE=OFF \
        -DENABLE_TESTS=OFF -DENABLE_LLVM=OFF \
        -DUSE_DISCORD_PRESENCE=OFF -DUSE_RETRO_ACHIEVEMENTS=OFF \
        -DUSE_MGBA=OFF -DENABLE_CLI_TOOL=OFF \
        -DENCODE_FRAMEDUMPS=OFF \
        -DBUILD_SHARED_LIBS=OFF -DLINUX_LOCAL_DEV=OFF

    cmake --build . -j"$JOBS"

    if [ ! -f "$DOLPHIN_BUILD/Binaries/dolphin-emu-nogui" ]; then
        print_error "Dolphin build failed!"
        exit 1
    fi

    "${CROSS_COMPILE}"strip --strip-unneeded "$DOLPHIN_BUILD/Binaries/dolphin-emu-nogui"

    mkdir -p "$DOLPHIN_INSTALL/bin"
    cp "$DOLPHIN_BUILD/Binaries/dolphin-emu-nogui" "$DOLPHIN_INSTALL/bin/"
    # Sys resource tree is required at runtime (shipped to /usr/share/dolphin-emu)
    mkdir -p "$DOLPHIN_INSTALL/sys"
    cp -r "$DOLPHIN_DIR/Data/Sys"/* "$DOLPHIN_INSTALL/sys/"

    print_step "Dolphin built and installed to $DOLPHIN_INSTALL"
}

build_armsx2() {
    print_step "Building ARMSX2 (SDL frontend)..."

    local ARMSX2_DIR="$EMU_DIR/armsx2"
    local ARMSX2_BUILD="$ARMSX2_DIR/build"
    local ARMSX2_INSTALL="$EMU_INSTALL/armsx2"
    local SDL3_INSTALL="$BUILD_DIR/sdl3-install"

    if [ ! -d "$SDL3_INSTALL/usr/lib" ]; then
        print_error "SDL3 not found at $SDL3_INSTALL - run build-tools.sh first"
        exit 1
    fi

    # plutovg/plutosvg have no distro packages; build the vendored 3rdparty
    # copies into a staging prefix the main configure can find. Must use the
    # same clang toolchain as ARMSX2 itself: static libs built by the GCC
    # toolchain carry GCC LTO bitcode that lld cannot link.
    local DEPS_INSTALL="$BUILD_DIR/armsx2-deps"
    if [ ! -f "$DEPS_INSTALL/lib/libplutosvg.a" ]; then
        for dep in plutovg plutosvg; do
            print_step "  Building vendored $dep..."
            cmake -S "$ARMSX2_DIR/3rdparty/$dep" -B "$ARMSX2_DIR/3rdparty/$dep/build" \
                -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/system/config/toolchain-aarch64-clang.cmake" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
                -DCMAKE_PREFIX_PATH="$DEPS_INSTALL" \
                -DCMAKE_FIND_ROOT_PATH="$DEPS_INSTALL" \
                -DBUILD_SHARED_LIBS=OFF \
                -DCMAKE_POSITION_INDEPENDENT_CODE=ON
            cmake --build "$ARMSX2_DIR/3rdparty/$dep/build" -j"$JOBS"
            cmake --install "$ARMSX2_DIR/3rdparty/$dep/build"
        done
    fi

    mkdir -p "$ARMSX2_BUILD"
    cd "$ARMSX2_BUILD"

    # SDL3/kmsdrm frontend: video via Vulkan VK_KHR_display (no compositor),
    # SDL3 for input/audio, Qt UI fully off.
    # Built with clang: the ARM64 JIT needs __attribute__((preserve_most)),
    # which GCC does not implement (vtlb.h hard-errors otherwise).
    cmake .. \
        -DCMAKE_TOOLCHAIN_FILE="$REPO_ROOT/system/config/toolchain-aarch64-clang.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$SDL3_INSTALL/usr;$DEPS_INSTALL" \
        -DCMAKE_FIND_ROOT_PATH="$SDL3_INSTALL/usr;$DEPS_INSTALL" \
        -DENABLE_SDL_FRONTEND=ON -DENABLE_QT_UI=OFF \
        -DENABLE_QT_DEBUGGER=OFF \
        -DHOST_PAGE_SIZE=4096 -DHOST_CACHE_LINE_SIZE=64 \
        -DSHADERC_LIBRARY=/usr/lib/aarch64-linux-gnu/libshaderc.so \
        -DUSE_VULKAN=ON -DUSE_OPENGL=ON \
        -DUSE_BACKTRACE=OFF \
        -DX11_API=OFF -DWAYLAND_API=OFF \
        -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
        -DLTO_PCSX2_CORE=ON

    cmake --build . -j"$JOBS"

    local SDL_BIN=$(find "$ARMSX2_BUILD/bin" -maxdepth 1 -type f -name 'armsx2*' ! -name '*.so' | head -1)
    if [ -z "$SDL_BIN" ]; then
        print_error "ARMSX2 build failed!"
        exit 1
    fi

    mkdir -p "$ARMSX2_INSTALL/bin"
    cp "$SDL_BIN" "$ARMSX2_INSTALL/bin/"
    "${CROSS_COMPILE}"strip --strip-unneeded "$ARMSX2_INSTALL/bin/$(basename "$SDL_BIN")" 2>/dev/null || true
    # Resources (shaders, FullscreenUI assets) are required at runtime
    cp -r "$ARMSX2_BUILD/bin/resources" "$ARMSX2_INSTALL/"

    print_step "ARMSX2 built and installed to $ARMSX2_INSTALL"
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
    CFLAGS="-O3 -mcpu=cortex-a75.cortex-a55 -flto=auto" LDFLAGS="-flto=auto" \
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

main() {
    echo -e "${GREEN}MIROKI Emulator Builds${NC}"
    echo ""

    check_dependencies
    setup_sdl_environment
    apply_all_patches

    # Multiple compilations required for mupen64plus, use separate script
    "$SCRIPTS_DIR/build-mupen64plus.sh"
    build_yabasanshiro
    build_flycast
    build_pcsx
    build_dolphin
    build_armsx2

    echo ""
    echo -e "${GREEN}MIROKI Emulator Builds Complete!${NC}"
    echo ""
    echo "Installation directory: $EMU_INSTALL"
    echo "  N64:      $EMU_INSTALL/mupen64plus"
    echo "  DC:       $EMU_INSTALL/flycast"
    echo "  PS1:      $EMU_INSTALL/pcsx"
    echo "  Saturn:   $EMU_INSTALL/yabasanshiro"
    echo "  GC/Wii:   $EMU_INSTALL/dolphin"
    echo "  PS2:      $EMU_INSTALL/armsx2"
}

main "$@"
