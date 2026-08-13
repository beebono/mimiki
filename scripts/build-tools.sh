#!/bin/bash
# MIROKI - Tools Build Script
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
SDL12_INSTALL="$BUILD_DIR/sdl12-install"
SDL3_INSTALL="$BUILD_DIR/sdl3-install"

# Build configuration
CROSS_COMPILE=aarch64-linux-gnu-
ARCH=arm64
HOST=aarch64-linux-gnu
CMAKE_TC="$REPO_ROOT/system/config/toolchain-aarch64-linux-gnu.cmake"

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
                --disable-libudev \
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

        sdl12-compat)
            mkdir -p "$build_dir"
            cd "$build_dir"

            cmake "$tool_dir" \
                -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DSDL2_INCLUDE_DIR="$SDL2_INSTALL/usr/include/SDL2" \
                -DSDL2_LIBRARY="$SDL2_INSTALL/usr/lib/libSDL2.so"
            ;;

        SDL3)
            # Needed by ARMSX2's pcsx2-sdl frontend (input/audio; video is
            # Vulkan VK_KHR_display). Same slim profile as the SDL2 build.
            mkdir -p "$build_dir"
            cd "$build_dir"

            cmake "$tool_dir" \
                -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DSDL_SHARED=ON \
                -DSDL_STATIC=OFF \
                -DSDL_TEST_LIBRARY=OFF \
                -DSDL_EXAMPLES=OFF \
                -DSDL_UNIX_CONSOLE_BUILD=ON \
                -DSDL_KMSDRM=ON \
                -DSDL_VULKAN=ON \
                -DSDL_ARMSVE2=OFF \
                -DSDL_OPENGLES=ON \
                -DSDL_OPENGL=OFF \
                -DSDL_X11=OFF \
                -DSDL_WAYLAND=OFF \
                -DSDL_ALSA=ON \
                -DSDL_PULSEAUDIO=OFF \
                -DSDL_PIPEWIRE=OFF \
                -DSDL_JACK=OFF \
                -DSDL_SNDIO=OFF \
                -DSDL_DBUS=OFF \
                -DSDL_IBUS=OFF \
                -DSDL_CAMERA=OFF \
                -DSDL_HIDAPI=ON \
                -DSDL_LIBUDEV=OFF # no udevd/netlink here; with libudev on, haptic init hard-fails and takes SDL_INIT_JOYSTICK|GAMEPAD|HAPTIC down with it
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

        sdl12-compat | SDL3)
            cd "$build_dir"
            cmake --build . -j"$(nproc)"
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

install_SDL3() {
    print_step "Installing SDL3 to staging directory..."

    cd "$TOOLS_DIR/SDL3/build"
    DESTDIR="$SDL3_INSTALL" cmake --install . --prefix /usr

    print_step "SDL3 installed to $SDL3_INSTALL!"
}

install_sdl12_compat() {
    print_step "Installing sdl12-compat to staging directory..."

    cd "$TOOLS_DIR/sdl12-compat/build"
    DESTDIR="$SDL12_INSTALL" cmake --install . --prefix /usr

    print_step "sdl12-compat installed to $SDL12_INSTALL!"
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

    # Finally build sdl12-compat against SDL2
    configure_tool "sdl12-compat"
    build_tool "sdl12-compat"
    install_sdl12_compat

    # SDL3 (independent of the SDL2 stack; used by ARMSX2)
    configure_tool "SDL3"
    build_tool "SDL3"
    install_SDL3

    # shaderc for ARMSX2 (PCSX2 pins; distro shaderc's glslang crashes)
    build_shaderc

    # Mesa (panfrost GL + panvk Vulkan) is no longer shipped - the libmali
    # blob stack is the runtime GPU driver (see build-rootfs.sh). Kept as an
    # opt-in fallback build: MIROKI_BUILD_MESA=1 make tools
    if [ "${MIROKI_BUILD_MESA:-0}" = "1" ]; then
        build_mesa
    fi
}

build_shaderc() {
    # PCSX2 dlopens libshaderc_shared.so.1 for Vulkan shader compilation and
    # requires its pinned shaderc/glslang combo: Ubuntu's libshaderc null-derefs
    # in glslang TSymbolTableLevel::clone() (thread pool allocator TLS) when
    # compiling from the GS thread. Versions + patch come straight from the
    # ARMSX2 tree (.github/workflows/scripts).
    local SHADERC=2026.2
    local GLSLANG=275822a6261ee689aadb1da5f09a0ec2f058685c
    local SPIRVHEADERS=58006c901d1d5c37dece6b6610e9af87fa951375
    local SPIRVTOOLS=6337eb62cadd7d124ac6789bf39c0f71148f0a73

    local CACHE="$TOOLS_DIR/.shaderc-cache"
    local SRC="$BUILD_DIR/shaderc-src"
    local INSTALL="$BUILD_DIR/shaderc-install"
    local PATCH="$REPO_ROOT/external/emulators/armsx2/.github/workflows/scripts/common/shaderc-changes.patch"

    if [ -f "$INSTALL/lib/libshaderc_shared.so.1" ]; then
        print_step "shaderc already built, skipping..."
        return
    fi

    print_step "Building shaderc $SHADERC (PCSX2 pins)..."

    mkdir -p "$CACHE"
    local url file
    for spec in \
        "https://github.com/google/shaderc/archive/v$SHADERC/shaderc-$SHADERC.tar.gz" \
        "https://github.com/KhronosGroup/glslang/archive/$GLSLANG/shaderc-glslang-$GLSLANG.tar.gz" \
        "https://github.com/KhronosGroup/SPIRV-Headers/archive/$SPIRVHEADERS/shaderc-spirv-headers-$SPIRVHEADERS.tar.gz" \
        "https://github.com/KhronosGroup/SPIRV-Tools/archive/$SPIRVTOOLS/shaderc-spirv-tools-$SPIRVTOOLS.tar.gz"; do
        file="$CACHE/$(basename "$spec")"
        [ -f "$file" ] || curl -L -o "$file" "$spec"
    done

    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar xf "$CACHE/shaderc-$SHADERC.tar.gz" -C "$SRC" --strip-components=1
    tar xf "$CACHE/shaderc-glslang-$GLSLANG.tar.gz" -C "$SRC/third_party"
    mv "$SRC/third_party/glslang-$GLSLANG" "$SRC/third_party/glslang"
    tar xf "$CACHE/shaderc-spirv-headers-$SPIRVHEADERS.tar.gz" -C "$SRC/third_party"
    mv "$SRC/third_party/SPIRV-Headers-$SPIRVHEADERS" "$SRC/third_party/spirv-headers"
    tar xf "$CACHE/shaderc-spirv-tools-$SPIRVTOOLS.tar.gz" -C "$SRC/third_party"
    mv "$SRC/third_party/SPIRV-Tools-$SPIRVTOOLS" "$SRC/third_party/spirv-tools"

    patch -d "$SRC" -p1 < "$PATCH"

    # Plain -O2, no LTO: the toolchain file's -flto=auto Release flags
    # miscompile glslang (ghost "'highp': only one precision qualifier"
    # errors on valid shaders, observed on device)
    cmake -S "$SRC" -B "$SRC/build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$CMAKE_TC" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
        -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
        -DCMAKE_INSTALL_PREFIX="$INSTALL" \
        -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON \
        -DSHADERC_SKIP_COPYRIGHT_CHECK=ON
    cmake --build "$SRC/build" --parallel "$(nproc)"
    cmake --install "$SRC/build"

    "${CROSS_COMPILE}"strip --strip-unneeded "$INSTALL"/lib/libshaderc_shared.so.1 2>/dev/null || true

    print_step "shaderc built!"
}

build_mesa() {
    print_step "Building Mesa (panfrost + panvk)..."

    local MESA_DIR="$TOOLS_DIR/mesa"
    local MESA_BUILD="$MESA_DIR/build"
    local MESA_INSTALL="$BUILD_DIR/mesa-install"
    local MESA_PATCHES="$REPO_ROOT/system/patches/tools/mesa"

    # Apply mimiki patches (sprd kmsro support)
    if [ ! -f "$MESA_DIR/.patches_applied" ] && [ -d "$MESA_PATCHES" ]; then
        cd "$MESA_DIR"
        for patch in "$MESA_PATCHES"/*.patch; do
            [ -f "$patch" ] || continue
            print_step "  Applying $(basename "$patch")..."
            git apply "$patch"
        done
        touch "$MESA_DIR/.patches_applied"
        cd "$REPO_ROOT"
    fi

    # Mesa needs meson >= 1.4; prefer a pipx/user install over the distro one
    local MESON=meson
    if [ -x "$HOME/.local/bin/meson" ]; then
        MESON="$HOME/.local/bin/meson"
    fi

    # Stage 00: native SPIRV-Tools library (Ubuntu ships no host dev package;
    # mesa_clc links it). Small cmake build, cached in build/.
    local SPV_SRC="$BUILD_DIR/spirv-tools-src"
    local HOST_DEPS="$BUILD_DIR/mesa-host-deps"
    if [ ! -f "$HOST_DEPS/usr/lib/pkgconfig/SPIRV-Tools.pc" ] && \
       [ ! -f "$HOST_DEPS/usr/lib/x86_64-linux-gnu/pkgconfig/SPIRV-Tools.pc" ]; then
        print_step "  Building native SPIRV-Tools..."
        if [ ! -d "$SPV_SRC" ]; then
            git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Tools.git "$SPV_SRC"
            git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers.git "$SPV_SRC/external/spirv-headers"
        fi
        # Real prefix, not DESTDIR: the .pc must carry the staged path or
        # meson strips the -L as a default system dir and the link fails
        cmake -S "$SPV_SRC" -B "$SPV_SRC/build" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$HOST_DEPS/usr" \
            -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON > /dev/null
        cmake --build "$SPV_SRC/build" -j"$(nproc)"
        cmake --install "$SPV_SRC/build" > /dev/null
    fi
    local HOST_PKG_PATH="$HOST_DEPS/usr/lib/pkgconfig"
    [ -d "$HOST_DEPS/usr/lib/x86_64-linux-gnu/pkgconfig" ] && \
        HOST_PKG_PATH="$HOST_DEPS/usr/lib/x86_64-linux-gnu/pkgconfig:$HOST_PKG_PATH"

    # Stage 0: native build of just the CLC tooling (mesa_clc/vtn_bindgen2).
    # Panfrost's precompiled internal shaders need these at build time, and a
    # cross build can't run target binaries, so they must be host tools.
    local CLC_BUILD="$MESA_DIR/build-native-clc"
    local CLC_INSTALL="$BUILD_DIR/mesa-clc-tools"
    if [ ! -x "$CLC_INSTALL/usr/bin/mesa_clc" ] || \
       [ ! -x "$CLC_INSTALL/usr/bin/panfrost_compile" ]; then
        if [ ! -f "$CLC_BUILD/build.ninja" ]; then
            # gallium-drivers=panfrost so panfrost_compile (the precomp
            # compiler the cross build consumes) gets built and installed
            PKG_CONFIG_PATH="$HOST_PKG_PATH:${PKG_CONFIG_PATH:-}" \
            $MESON setup "$CLC_BUILD" "$MESA_DIR" \
                --buildtype release \
                --prefix /usr \
                -Dplatforms= \
                -Degl=disabled \
                -Dgbm=disabled \
                -Dglx=disabled \
                -Dgles1=disabled \
                -Dgles2=disabled \
                -Dopengl=false \
                -Dgallium-drivers=panfrost \
                -Dvulkan-drivers= \
                -Dtools= \
                -Dmesa-clc=enabled \
                -Dinstall-mesa-clc=true \
                -Dprecomp-compiler=enabled \
                -Dinstall-precomp-compiler=true
        fi
        ninja -C "$CLC_BUILD" -j"$(nproc)"
        DESTDIR="$CLC_INSTALL" ninja -C "$CLC_BUILD" install
    fi

    # Stage 1: the actual cross build, consuming the host CLC tools
    if [ ! -f "$MESA_BUILD/build.ninja" ]; then
        PATH="$CLC_INSTALL/usr/bin:$PATH" $MESON setup "$MESA_BUILD" "$MESA_DIR" \
            --cross-file "$CONFIG_DIR/meson-cross-aarch64.txt" \
            --buildtype release \
            --prefix /usr \
            -Dplatforms= \
            -Degl=enabled \
            -Dgbm=enabled \
            -Dglx=disabled \
            -Dglvnd=disabled \
            -Dgles1=disabled \
            -Dgles2=enabled \
            -Dopengl=true \
            -Dgallium-drivers=panfrost \
            -Dvulkan-drivers=panfrost \
            -Dtools= \
            -Dllvm=disabled \
            -Dmesa-clc=system \
            -Dprecomp-compiler=system \
            -Dzstd=enabled \
            -Dvalgrind=disabled \
            -Dlibunwind=disabled
    fi

    PATH="$CLC_INSTALL/usr/bin:$PATH" ninja -C "$MESA_BUILD" -j"$(nproc)"
    PATH="$CLC_INSTALL/usr/bin:$PATH" DESTDIR="$MESA_INSTALL" ninja -C "$MESA_BUILD" install

    print_step "Mesa installed to $MESA_INSTALL!"
}

main() {
    print_step "MIROKI Tool Builder"

    check_dependencies
    build_all_tools

    print_step "MIROKI Tool Building Completed!"
}

main "$@"
