#!/bin/bash
# MIMIKI - Tools Build Script
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Paths
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
TOOLS_DIR="$REPO_ROOT/external/tools"
CONFIG_DIR="$REPO_ROOT/system/config"
SDL2_INSTALL="$BUILD_DIR/sdl2-install"

# Build configuration
CROSS_COMPILE=aarch64-linux-gnu-
ARCH=arm64
HOST=aarch64-linux-gnu

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

    if ! command -v ${CROSS_COMPILE}g++ &> /dev/null; then
        missing_deps+=("${CROSS_COMPILE}g++")
    fi

    for tool in make wget tar autoconf automake libtoolize pkg-config; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        exit 1
    fi

    print_step "All dependencies found!"
}

configure_tool() {
    local tool=$1
    local tool_dir="$TOOLS_DIR/$tool"
    local build_dir="$tool_dir/build"

    print_step "Configuring $tool..."
    cd "$tool_dir"

    case $tool in
        busybox)
            if [ -f "$CONFIG_DIR/busybox.config" ]; then
                cp "$CONFIG_DIR/busybox.config" .config
            else
                make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE defconfig
            fi
            ;;

        exfatprogs)
            # Run autogen if configure doesn't exist yet
            if [ ! -f configure ]; then
                print_step "Running autogen.sh..."
                ./autogen.sh
            fi

            mkdir -p "$build_dir"
            cd "$build_dir"

            "$tool_dir/configure" \
                --host=$HOST \
                --prefix=/usr \
                --sbindir=/usr/sbin \
                --disable-shared \
                --enable-static
            ;;

        gptfdisk)
            # N/A
            ;;

        SDL2)
            mkdir -p "$build_dir"
            cd "$build_dir"

            "$tool_dir/configure" \
                --host=$HOST \
                --prefix=/usr \
                --disable-static \
                --enable-shared \
                --enable-video \
                --enable-video-kmsdrm \
                --disable-kmsdrm-shared \
                --enable-video-vulkan \
                --disable-video-opengl \
                --enable-video-opengles \
                --disable-video-opengles1 \
                --enable-video-opengles2 \
                --disable-video-x11 \
                --disable-video-wayland \
                --disable-video-vivante \
                --disable-video-directfb \
                --disable-video-dummy \
                --disable-video-offscreen \
                --disable-render-d3d \
                --enable-joystick \
                --enable-haptic \
                --enable-events \
                --enable-timers \
                --enable-file \
                --enable-loadso \
                --enable-cpuinfo \
                --enable-arm-simd \
                --enable-arm-neon \
                --enable-atomic \
                --enable-audio \
                --enable-alsa \
                --disable-pulseaudio \
                --disable-jack \
                --disable-pipewire \
                --disable-oss \
                --disable-sndio \
                --disable-arts \
                --disable-esd \
                --disable-diskaudio \
                --disable-dummyaudio \
                --disable-libsamplerate \
                --disable-dbus \
                --disable-ibus \
                --disable-fcitx \
                --disable-ime \
                --disable-sensor \
                --disable-power \
                --disable-locale \
                --disable-rpath \
                --disable-libudev
            ;;

        SDL2_image)
            mkdir -p "$build_dir"
            cd "$build_dir"

            # Set PKG_CONFIG_PATH to find custom SDL2
            local sdl2_install="$BUILD_DIR/sdl2-install"
            export PKG_CONFIG_PATH="$sdl2_install/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
            export SDL2_CONFIG="$sdl2_install/usr/bin/sdl2-config"

            "$tool_dir/configure" \
                --host=$HOST \
                --prefix=/usr \
                --disable-static \
                --enable-shared \
                --enable-png \
                --disable-jpg \
                --disable-jxl \
                --disable-tif \
                --disable-webp \
                --disable-avif \
                --with-sdl-prefix="$sdl2_install/usr"
            ;;

        alsa-utils)
            # Run autoreconf if configure doesn't exist
            if [ ! -f "$tool_dir/configure" ]; then
                print_step "Running autoreconf..."
                cd "$tool_dir"
                autoreconf -vif
            fi

            mkdir -p "$build_dir"
            cd "$build_dir"

            "$tool_dir/configure" \
                --host=$HOST \
                --prefix=/usr \
                --disable-alsamixer \
                --disable-alsaconf \
                --disable-alsaloop \
                --disable-alsaucm \
                --disable-topology \
                --disable-bat \
                --disable-nls \
                --disable-xmlto \
                --with-curses=ncurses
            ;;
    esac

    print_step "$tool configured!"
}

build_tool() {
    local tool=$1
    local tool_dir="$TOOLS_DIR/$tool"
    local build_dir="$tool_dir/build"

    print_step "Building $tool..."

    case $tool in
        busybox)
            cd "$tool_dir"
            make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j"$(nproc)"
            ;;

        exfatprogs)
            cd "$build_dir"
            make LDFLAGS="-static" -j"$(nproc)"
            ;;

        gptfdisk)
            cd "$tool_dir"
            make CXX=${CROSS_COMPILE}g++ LDFLAGS="-static" -j"$(nproc)" sgdisk
            ;;

        SDL2 | SDL2_image | alsa-utils)
            cd "$build_dir"
            make -j"$(nproc)"
            ;;
    esac

    print_step "$tool built!"
}

install_SDL2_base() {
    # SDL2 needs a staging directory so SDL2_image can link against it
    print_step "Installing SDL2 to staging directory..."

    cd "$TOOLS_DIR/SDL2/build"
    make DESTDIR="$SDL2_INSTALL" install

    print_step "SDL2 base installed to $SDL2_INSTALL!"
}

install_SDL2_image() {
    # Install SDL2_image to the same staging directory
    print_step "Installing SDL2_image to staging directory..."

    cd "$TOOLS_DIR/SDL2_image/build"
    make DESTDIR="$SDL2_INSTALL" install

    print_step "SDL2_image installed to $SDL2_INSTALL!"
}

build_all_tools() {
    # Build tools that don't depend on others first
    local basic_tools=(busybox exfatprogs gptfdisk alsa-utils)

    for tool in "${basic_tools[@]}"; do
        configure_tool "$tool"
        build_tool "$tool"
    done

    # Build and install SDL2 before SDL2_image (SDL2_image depends on SDL2)
    configure_tool "SDL2"
    build_tool "SDL2"
    install_SDL2_base

    # Now build SDL2_image with SDL2 available
    configure_tool "SDL2_image"
    build_tool "SDL2_image"
    install_SDL2_image
}

main() {
    print_step "MIMIKI Tool Builder"

    check_dependencies
    build_all_tools

    print_step "MIMIKI Tool Building Completed!"
}

main "$@"
