#!/bin/bash
# MIMIKI - RetroArch Build Script
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
RA_DIR="$REPO_ROOT/external/retroarch"
RA_INSTALL="$BUILD_DIR/retroarch"
SDL2_INSTALL="$BUILD_DIR/sdl2-install"

# Cross-compilation
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
CMAKE_TC="$REPO_ROOT/system/config/toolchain-aarch64-linux-gnu.cmake"
HOST=aarch64-linux-gnu
JOBS=$(nproc)

# Core directories
RAFRONT_DIR="$RA_DIR/frontend"
M64P_DIR="$RA_DIR/mupen64plus-libretro-nx"
FLYCAST_DIR="$RA_DIR/flycast"
PCSXRA_DIR="$RA_DIR/pcsx-rearmed"
PPSSPP_DIR="$RA_DIR/ppsspp"

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
    mkdir -p "$RA_INSTALL/bin"
    mkdir -p "$RA_INSTALL/lib/cores"
}

apply_patches() {
    print_step "Applying patches to RetroArch..."

    local PATCHES_DIR="$REPO_ROOT/system/patches/retroarch"

    if [ ! -d "$PATCHES_DIR" ]; then
        print_warning "No RetroArch/Core patches found, skipping..."
        return
    fi

    cd "$RAFRONT_DIR"

    if [ ! -f ".patches_applied" ]; then
        for patch in "$PATCHES_DIR/frontend"/*.patch; do
            if [ -f "$patch" ]; then
                local patch_name=$(basename "$patch")
                print_step "  Applying $patch_name..."
                git apply "$patch"
            fi
        done

        touch .patches_applied
    fi

    cd "$M64P_DIR"

    if [ ! -f ".patches_applied" ]; then
        for patch in "$PATCHES_DIR/mupen64plus"/*.patch; do
            if [ -f "$patch" ]; then
                local patch_name=$(basename "$patch")
                print_step "  Applying $patch_name..."
                git apply "$patch"
            fi
        done

        touch .patches_applied
    fi

    print_step "RetroArch patches applied successfully!"
}

build_frontend() {
    print_step "Building RetroArch Frontend..."

    cd "$RAFRONT_DIR"

    ./configure --prefix=/usr --bindir=/usr/bin --datarootdir=/mnt/games/bios --host=$HOST \
        --disable-nvda --disable-patch --disable-xdelta --disable-video_filter \
        --disable-winrawinput --disable-dsp_filter --disable-blissbox --disable-gdi \
        --disable-sixel --disable-libretrodb --disable-menu --disable-gfx_widgets \
        --disable-runahead --disable-dsound --disable-xaudio --disable-wasapi \
        --disable-winmm --disable-nearest_resampler --disable-cc_resampler --disable-ssl \
        --disable-overlay --enable-sdl2 --disable-libusb --disable-systemd --disable-udev \
        --enable-threads --enable-thread_storage --disable-ffmpeg --disable-ssa \
        --enable-dylib --disable-networking --disable-ifinfo --disable-networkgamepad \
        --disable-netplaydiscovery --disable-d3d9 --disable-d3d10 --disable-d3d11 \
        --disable-d3d12 --disable-d3dx --disable-dinput --disable-opengl1 --enable-opengles \
        --enable-opengles3 --enable-opengles3_1 --enable-opengles3_2 --disable-x11 \
        --disable-xrandr --disable-xscrnsaver --disable-xi2 --disable-xinerama --disable-kms \
        --disable-wayland --disable-libdecor --enable-dynamic_egl --enable-egl --disable-vg \
        --disable-cg --disable-builtinzlib --enable-zlib --enable-alsa --disable-rpiled \
        --enable-tinyalsa --disable-audioio --disable-oss --disable-rsound --disable-roar \
        --enable-plain_drm --disable-jack --disable-coreaudio --disable-pipewire --disable-pulse \
        --disable-freetype --disable-stb_font --disable-stb_image --disable-stb_vorbis \
        --disable-ibxm --disable-v4l2 --disable-7zip --disable-zstd --disable-flac \
        --disable-dr_mp3 --disable-builtinflac --disable-online_updater --disable-update_cores \
        --disable-update_core_info --disable-update_assets --disable-parport --disable-imageviewer \
        --enable-mmap --disable-qt --disable-cheevos --disable-cheevos_rvz --disable-discord \
        --disable-cheats --disable-rewind --disable-bsv_movie --disable-accessibility \
        --disable-translate --disable-shaderpipeline --enable-vulkan --disable-rpng --disable-rbmp \
        --disable-rjpeg --disable-rtga --disable-rwav --disable-audiomixer --disable-langextra \
        --disable-screenshots --disable-videoprocessor --disable-videocore --disable-cdrom \
        --disable-glx --enable-slang --enable-glslang --enable-builtinglslang \
        --enable-spirv_cross --disable-crtswitchres --enable-memfd_create --disable-microphone \
        --disable-test_drivers --disable-smbclient

    make -j${JOBS}

    if [ ! -f "$RAFRONT_DIR/retroarch" ]; then
        print_error "RetroArch Frontend build failed!"
        exit 1
    fi

    print_step "RetroArch Frontend built successfully!"
}

build_mupen() {
    print_step "Building mupen64plus-next core..."

    cd "$M64P_DIR"

    make -j${JOBS} \
        all platform=unix CC=${CROSS_COMPILE}gcc CXX=${CROSS_COMPILE}g++ \
        CPUFLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        WITH_DYNAREC=aarch64 FORCE_GLES3=1 LLE=0 HAVE_PARALLEL_RSP=0 HAVE_PARALLEL_RDP=0

    if [ ! -f "$M64P_DIR/mupen64plus_next_libretro.so" ]; then
        print_error "Mupen64plus-next core build failed!"
        exit 1
    fi

    print_step "Mupen64plus-next core built successfully!"
}

build_flycast() {
    print_step "Building flycast core..."

    mkdir -p "$FLYCAST_DIR/build"
    cd "$FLYCAST_DIR/build"

    cmake ../ \
        -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TC}" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        -DCMAKE_CXX_FLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        -DLIBRETRO=ON -DUSE_DX9=OFF -DUSE_DX11=OFF -DUSE_OPENGL=OFF -DUSE_LIBAO=OFF \
        -DUSE_PULSEAUDIO=OFF -DUSE_BREAKPAD=OFF -DUSE_LUA=OFF -DWITH_LZMA_ASM=OFF
    make -j${JOBS}

    if [ ! -f "$FLYCAST_DIR/build/flycast_libretro.so" ]; then
        print_error "Flycast core build failed!"
        exit 1
    fi

    print_step "Flycast core built successfully!"
}

build_pcsx() {
    print_step "Building PCSX-ReArmed core..."

    cd "$PCSXRA_DIR"

    export CFLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto"
    export LDFLAGS="-flto=auto"
    ./configure --sound-drivers=alsa --enable-threads --enable-dynamic --dynarec=ari64
        
    make -f Makefile.libretro -j${JOBS} \
        CC=${CROSS_COMPILE}gcc CXX=${CROSS_COMPILE}g++ \
        PLATFORM=libretro HAVE_PHYSICAL_CDROM=0

    if [ ! -f "$PCSXRA_DIR/pcsx_rearmed_libretro.so" ]; then
        print_error "PCSX-ReArmed core build failed!"
        exit 1
    fi

    print_step "PCSX-ReArmed core built successfully!"
}

build_ppsspp() {
    print_step "Building PPSSPP core..."

    mkdir -p "$PPSSPP_DIR/build"
    cd "$PPSSPP_DIR/build"

    cmake ../ \
        -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TC}" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        -DCMAKE_CXX_FLAGS="-Ofast -march=armv8-a+simd -mtune=cortex-a55 -flto=auto" \
        -DLIBRETRO=ON -DUSE_DX11_VULKAN=OFF -DUSE_WAYLAND_WSI=OFF -DUSE_VULKAN_DISPLAY_KHR=ON \
        -DHEADLESS=OFF -DUSE_FFMPEG=OFF -DUSE_DISCORD=OFF -DUSE_MINIUPNPC=OFF \
        -DUSE_SYSTEM_SNAPPY=OFF -DUSE_SYSTEM_FFMPEG=OFF -DUSE_SYSTEM_LIBZIP=OFF \
        -DUSE_SYSTEM_LIBSDL2=ON -DUSE_SYSTEM_LIBPNG=OFF -DUSE_SYSTEM_ZSTD=OFF \
        -DUSE_SYSTEM_MINIUPNPC=OFF
    make -j${JOBS}

    if [ ! -f "$PPSSPP_DIR/build/lib/ppsspp_libretro.so" ]; then
        print_error "PPSSPP core build failed!"
        exit 1
    fi
}

strip_binaries() {
    print_step "Stripping binaries to reduce size..."

    "${CROSS_COMPILE}"strip --strip-unneeded "$RAFRONT_DIR/retroarch"
    "${CROSS_COMPILE}"strip --strip-unneeded "$M64P_DIR/mupen64plus_next_libretro.so"
    "${CROSS_COMPILE}"strip --strip-unneeded "$FLYCAST_DIR/build/flycast_libretro.so"
    "${CROSS_COMPILE}"strip --strip-unneeded "$PCSXRA_DIR/pcsx_rearmed_libretro.so"
    "${CROSS_COMPILE}"strip --strip-unneeded "$PPSSPP_DIR/build/lib/ppsspp_libretro.so"

    print_step "Binaries stripped!"
}

install_retroarch() {
    print_step "Installing RetroArch to build directory..."

    cp "$RAFRONT_DIR/retroarch" "$RA_INSTALL/bin/"
    cp "$M64P_DIR/mupen64plus_next_libretro.so" "$RA_INSTALL/lib/cores/"
    cp "$FLYCAST_DIR/build/flycast_libretro.so" "$RA_INSTALL/lib/cores/"
    cp "$PCSXRA_DIR/pcsx_rearmed_libretro.so" "$RA_INSTALL/lib/cores/"
    cp "$PPSSPP_DIR/build/lib/ppsspp_libretro.so" "$RA_INSTALL/lib/cores/"

    print_step "RetroArch installed to $RA_INSTALL"
}

main() {
    echo -e "${GREEN}MIMIKI RetroArch Build${NC}"
    echo ""

    check_dependencies
    setup_sdl2_environment
    apply_patches
    build_frontend
    build_mupen
    build_flycast
    build_pcsx
    build_ppsspp
    strip_binaries
    install_retroarch

    echo ""
    echo -e "${GREEN}MIMIKI RetroArch Build Complete!${NC}"
    echo ""
    echo "Installation directory: $RETROARCH_INSTALL"
    echo "  Executable:      build/retroarch/bin/retroarch"
    echo "  Plugins:         build/retroarch/lib/cores/*.so"
}

main "$@"
