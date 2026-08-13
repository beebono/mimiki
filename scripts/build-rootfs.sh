#!/bin/bash
# MIROKI - Rootfs Build Script
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
ROOTFS_SKELETON="$REPO_ROOT/system/rootfs"
ROOTFS_BUILD="$BUILD_DIR/rootfs-temp"
ROOTFS_FINAL="$BUILD_DIR/rootfs"
ROOTFS_SQUASHFS="$BUILD_DIR/rootfs.squashfs"
LAUNCHER_DIR="$REPO_ROOT/system/launcher"
TOOLS_DIR="$REPO_ROOT/external/tools"
BUSYBOX_DIR="$TOOLS_DIR/busybox"

# Sysroots
SYSROOT_OLD="/usr/aarch64-linux-gnu"  # Old toolchain location
SYSROOT="/usr/lib/aarch64-linux-gnu"  # Multiarch location

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

    for tool in make wget tar mksquashfs; do
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

populate_rootfs() {
    print_step "Populating rootfs..."

    rm -rf "$ROOTFS_BUILD"
    mkdir -p "$ROOTFS_BUILD"
    # Create directory structure
    mkdir -p "$ROOTFS_BUILD"/{bin,dev,dev/pts,dev/shm,etc,lib,root,mnt/games,mnt/games2,proc,run,sbin,sys,tmp,usr/bin,usr/lib,usr/share,usr/sbin,var}

    if [ -d "$ROOTFS_SKELETON" ]; then
        cp -a "$ROOTFS_SKELETON"/* "$ROOTFS_BUILD"/ 2>/dev/null || true
    fi

    print_step "Preliminary rootfs ready!"
}

install_launcher() {
    print_step "Installing Launcher..."

    if [ -f "$REPO_ROOT/system/glinfo/build/mimiki-glinfo" ]; then
        cp "$REPO_ROOT/system/glinfo/build/mimiki-glinfo" "$ROOTFS_BUILD/usr/bin/"
        chmod +x "$ROOTFS_BUILD/usr/bin/mimiki-glinfo"
    fi

    if [ -f "$REPO_ROOT/system/aggregator/build/mimiki-inputd" ]; then
        cp "$REPO_ROOT/system/aggregator/build/mimiki-inputd" "$ROOTFS_BUILD/usr/bin/"
        chmod +x "$ROOTFS_BUILD/usr/bin/mimiki-inputd"
    fi

    if [ -f "$REPO_ROOT/system/launcher/build/mimiki-launcher" ]; then
        cp "$REPO_ROOT/system/launcher/build/mimiki-launcher" "$ROOTFS_BUILD/usr/bin/"
        chmod +x "$ROOTFS_BUILD/usr/bin/mimiki-launcher"
    else
        print_warning "Launcher not built! Run 'make launcher' first."
    fi

    # ncurses terminfo support
    mkdir -p "$ROOTFS_BUILD/usr/share/terminfo/l"
    cp "/usr/share/terminfo/l/linux" "$ROOTFS_BUILD/usr/share/terminfo/l/"

    print_step "Launcher installed!"
}

install_busybox() {
    print_step "Installing busybox to rootfs..."

    cd "$BUSYBOX_DIR"
    make CONFIG_PREFIX="$ROOTFS_BUILD" install

    print_step "Busybox installed!"
}

install_alsa() {
    print_step "Installing ALSA to rootfs..."

    local ALSA_BUILD="$TOOLS_DIR/alsa-utils/build"
    if [ -f "$ALSA_BUILD/amixer/amixer" ]; then
        cp "$ALSA_BUILD/amixer/amixer" "$ROOTFS_BUILD/usr/bin/"
        cp "$ALSA_BUILD/alsactl/alsactl" "$ROOTFS_BUILD/usr/bin/" 2>/dev/null || true
        # aplay primes the softvol control at boot (see rcS)
        cp "$ALSA_BUILD/aplay/aplay" "$ROOTFS_BUILD/usr/bin/" 2>/dev/null || true
        print_step "ALSA utilities installed!"
    else
        print_warning "ALSA utilities not found! Run 'make tools' first."
    fi

    print_step "ALSA installed!"
}

install_libraries() {
    print_step "Installing essential libraries..."

    mkdir -p "$ROOTFS_BUILD/lib"
    mkdir -p "$ROOTFS_BUILD/usr/lib"

    # Essential C library (try both old and new locations)
    cp -L "$SYSROOT_OLD/lib/ld-linux-aarch64.so.1" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/ld-linux-aarch64.so.1" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/libc.so.6" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/libc.so.6" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/libm.so.6" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/libm.so.6" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/libpthread.so.0" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/libpthread.so.0" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/libdl.so.2" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/libdl.so.2" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/librt.so.1" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/librt.so.1" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/libstdc++.so.6" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/libstdc++.so.6" "$ROOTFS_BUILD/lib/" || true
    cp -L "$SYSROOT_OLD/lib/libgcc_s.so.1" "$ROOTFS_BUILD/lib/" 2>/dev/null || cp -L "$SYSROOT/libgcc_s.so.1" "$ROOTFS_BUILD/lib/" || true

    # Additional libraries (Audio)
    cp -L "$SYSROOT/libasound.so.2" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libasound not found"

    # ALSA configuration files
    if [ -d "/usr/share/alsa" ]; then
        mkdir -p "$ROOTFS_BUILD/usr/share/alsa"
        cp -a /usr/share/alsa/* "$ROOTFS_BUILD/usr/share/alsa/"
        print_step "ALSA config files installed!"
    else
        print_warning "ALSA config files not found at /usr/share/alsa"
    fi

    # Additional libraries (GPU): the ARM libmali blob stack (GLES + Vulkan,
    # both with working direct-KMS presentation - VK_KHR_display enumerates
    # the panel on this ICD, unlike panvk). The wrapper shims from lib/mali/
    # are installed AT the canonical sonames (libgbm.so.1, libEGL.so.1, ...)
    # so nothing can resolve to a mesa copy; they dispatch into libmali via
    # libmali-hook. Install BEFORE resolve_library_closure so the resolver
    # sees these sonames as present and never pulls mesa from the sysroot.
    local BLOBS="$REPO_ROOT/system/prebuilts/libmali-blobs"
    mkdir -p "$ROOTFS_BUILD/usr/share/vulkan/icd.d"
    # Core blob + dispatch lib + hook (symlink chains preserved with -a)
    cp -a "$BLOBS/lib"/libmali*.so* "$ROOTFS_BUILD/usr/lib/"
    cp -a "$BLOBS/lib"/libMaliVulkan.so* "$ROOTFS_BUILD/usr/lib/"
    # Wrapper shims at canonical GL/GBM sonames
    cp -a "$BLOBS/lib/mali"/*.so* "$ROOTFS_BUILD/usr/lib/"
    # Vulkan loader + mali ICD
    cp -a "$BLOBS/lib"/libvulkan.so* "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "Vulkan loader not found"
    cp "$BLOBS/icd.d/mali.json" "$ROOTFS_BUILD/usr/share/vulkan/icd.d/"
    # ARM WSI layer (implicit): the ICD alone reports 0 displays - this layer
    # provides VK_KHR_display enumeration + VK_KHR_swapchain over DRM/KMS,
    # allocating scanout buffers from /dev/dma_heap/linux,cma
    mkdir -p "$ROOTFS_BUILD/usr/share/vulkan/implicit_layer.d"
    cp -a "$BLOBS/lib"/libVkLayer_window_system_integration.so "$ROOTFS_BUILD/usr/lib/"
    cp "$BLOBS/implicit_layer.d"/*.json "$ROOTFS_BUILD/usr/share/vulkan/implicit_layer.d/"
    cp -a "$SYSROOT"/libdrm.so* "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libdrm not found"

    # Kernel modules loaded by rcS: mali_kbase (libmali is its userspace half)
    # and sprd-audcp-boot (audio DSP boot, firmware in the squashfs)
    mkdir -p "$ROOTFS_BUILD/lib/modules"
    cp -a "$BUILD_DIR/modules"/*.ko "$ROOTFS_BUILD/lib/modules/" 2>/dev/null || print_warning "Kernel modules not found (run 'make boot' first)"

    # Firmware (AGDSP audio DSP; also in the initramfs for early probe)
    mkdir -p "$ROOTFS_BUILD/lib/firmware"
    cp -a "$REPO_ROOT/system/prebuilts/firmware"/* "$ROOTFS_BUILD/lib/firmware/" 2>/dev/null || print_warning "Firmware blobs not found"

    # Additional libraries (Launcher)
    cp -L "$SYSROOT/libncurses.so.6" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libncurses not found"
    cp -L "$SYSROOT/libtinfo.so.6" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libtinfo not found"

    # Additional libraries (SDL2)
    cp -a "$BUILD_DIR"/sdl2-install/usr/lib/libSDL2*.so* "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "SDL2 not found"

    # Additional libraries (Emulators)
    # mupen64plus
    cp -L "$SYSROOT/libpng16.so.16" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libpng16 not found"
    cp -L "$SYSROOT/libz.so.1" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libz not found"
    # yabasanshiro
    cp -L "$SYSROOT/libglut.so.3.12" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libglut not found"
    # PCSX2-pinned shaderc build (Ubuntu's crashes in glslang from the GS
    # thread); PCSX2 dlopens libshaderc_shared.so.1 by preference
    cp -a "$BUILD_DIR/shaderc-install/lib"/libshaderc_shared.so* "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "shaderc (PCSX2 pin) not built - run 'make tools'"
    # flycast
    cp -L "$SYSROOT/libgomp.so.1" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libgomp not found"
    cp -L "$SYSROOT/libudev.so.1" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libudev not found"
    cp -L "$SYSROOT/libcap.so.2" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libcap not found"
    cp -L "$SYSROOT/libmvec.so.1" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libmvec not found"    
    # pcsx
    cp -L "$BUILD_DIR/sdl12-install/usr/lib/libSDL-1.2.so.0" "$ROOTFS_BUILD/usr/lib" 2>/dev/null || print_warning "sdl12-compat not found"
    # armsx2 (SDL3 for input/audio; shaderc dlopen'd at runtime as libshaderc.so.1)
    cp -a "$BUILD_DIR"/sdl3-install/usr/lib/libSDL3.so* "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "SDL3 not found"
    for lib in libdbus-1.so.3 libcurl.so.4 libwebp.so.7 libfreetype.so.6 \
               liblz4.so.1 libjpeg.so.8 libzstd.so.1; do
        cp -L "$SYSROOT/$lib" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "$lib not found"
    done
    # dolphin
    for lib in libevdev.so.2 libbz2.so.1.0; do
        cp -L "$SYSROOT/$lib" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "$lib not found"
    done
    # ppsspp covered by previous libraries

    print_step "Libraries installed!"
}

install_emulators() {
    print_step "Installing emulators..."

    if [ -d "$BUILD_DIR/emulators/mupen64plus" ]; then
        cp -a "$BUILD_DIR/emulators/mupen64plus/lib/libmupen64plus.so.2" \
            "$ROOTFS_BUILD/usr/lib/"
        # Binaries/data stay in the squashfs; the seeded config on the games
        # partition points PluginDir/SharedDataPath here
        mkdir -p "$ROOTFS_BUILD/usr/lib/mupen64plus" "$ROOTFS_BUILD/usr/share/mupen64plus"
        cp -a "$BUILD_DIR/emulators/mupen64plus/lib/plugins"/* \
            "$ROOTFS_BUILD/usr/lib/mupen64plus/"
        cp -a "$BUILD_DIR/emulators/mupen64plus/GLideN64.custom.ini" \
            "$ROOTFS_BUILD/usr/share/mupen64plus/"
        cp -a "$BUILD_DIR/emulators/mupen64plus/bin/mupen64plus" \
            "$ROOTFS_BUILD/usr/bin/"

        print_step "mupen64plus installed!"
    fi

    if [ -d "$BUILD_DIR/emulators/yabasanshiro" ]; then
        cp -a "$BUILD_DIR/emulators/yabasanshiro/bin/yabasanshiro" \
            "$ROOTFS_BUILD/usr/bin/"

        print_step "yabasanshiro installed!"
    fi

    if [ -d "$BUILD_DIR/emulators/flycast" ]; then
        cp -a "$BUILD_DIR/emulators/flycast/bin/flycast" \
            "$ROOTFS_BUILD/usr/bin/"

        print_step "flycast installed!"
    fi

    if [ -d "$BUILD_DIR/emulators/pcsx" ]; then
        # Menu skin: pcsx looks in <exe-dir>/skin; without it the menu (and
        # its "no BIOS" messages) render invisible
        mkdir -p "$ROOTFS_BUILD/usr/bin/skin"
        cp -a "$REPO_ROOT/external/emulators/pcsx-rearmed/frontend/320240/skin"/* \
            "$ROOTFS_BUILD/usr/bin/skin/"
        cp -a "$BUILD_DIR/emulators/pcsx/bin/pcsx" \
            "$ROOTFS_BUILD/usr/bin/"

        print_step "pcsx-rearmed installed!"
    fi

    if [ -d "$BUILD_DIR/emulators/dolphin" ]; then
        cp -a "$BUILD_DIR/emulators/dolphin/bin/dolphin-emu-nogui" \
            "$ROOTFS_BUILD/usr/bin/"
        mkdir -p "$ROOTFS_BUILD/usr/share/dolphin-emu/sys"
        cp -ar "$BUILD_DIR/emulators/dolphin/sys"/* \
            "$ROOTFS_BUILD/usr/share/dolphin-emu/sys/"

        print_step "dolphin installed!"
    fi

    if [ -d "$BUILD_DIR/emulators/armsx2" ]; then
        # Binary and resources must be co-located: PCSX2 resolves its
        # resource dir relative to the real binary path (/proc/self/exe)
        mkdir -p "$ROOTFS_BUILD/usr/share/armsx2"
        cp -a "$BUILD_DIR/emulators/armsx2/bin"/* \
            "$ROOTFS_BUILD/usr/share/armsx2/"
        cp -ar "$BUILD_DIR/emulators/armsx2/resources" \
            "$ROOTFS_BUILD/usr/share/armsx2/"
        ln -sf ../share/armsx2/armsx2-sdl "$ROOTFS_BUILD/usr/bin/armsx2-sdl"

        print_step "armsx2 installed!"
    fi

    print_step "Emulators installed!"
}

resolve_library_closure() {
    # Walk every ELF in the rootfs, copy any missing NEEDED library from the
    # sysroot, and repeat until stable. Hand-listing misses transitive deps
    # (libcurl -> nghttp2/idn2/ssl, libpcap, ...).
    print_step "Resolving shared library closure..."

    local readelf="${CROSS_COMPILE:-aarch64-linux-gnu-}readelf"
    local pass=0 copied=1
    while [ $copied -gt 0 ] && [ $pass -lt 10 ]; do
        copied=0
        pass=$((pass + 1))
        local needed
        needed=$(find "$ROOTFS_BUILD/usr/bin" "$ROOTFS_BUILD/usr/lib" \
                      "$ROOTFS_BUILD/lib" "$ROOTFS_BUILD/usr/share/armsx2" \
                      -type f 2>/dev/null | while read -r f; do
                     $readelf -d "$f" 2>/dev/null | grep NEEDED
                 done | sed 's/.*\[\(.*\)\]/\1/' | sort -u)

        for lib in $needed; do
            # Already present anywhere in the rootfs?
            if [ -e "$ROOTFS_BUILD/usr/lib/$lib" ] || [ -e "$ROOTFS_BUILD/lib/$lib" ]; then
                continue
            fi
            if [ -e "$SYSROOT/$lib" ]; then
                cp -L "$SYSROOT/$lib" "$ROOTFS_BUILD/usr/lib/"
                print_step "  + $lib"
                copied=$((copied + 1))
            elif [ -e "$SYSROOT_OLD/lib/$lib" ]; then
                cp -L "$SYSROOT_OLD/lib/$lib" "$ROOTFS_BUILD/usr/lib/"
                print_step "  + $lib"
                copied=$((copied + 1))
            else
                print_warning "  cannot resolve $lib (not in sysroot)"
            fi
        done
    done

    print_step "Library closure resolved (${pass} passes)!"
}

set_permissions() {
    print_step "Setting correct permissions..."

    cd "$ROOTFS_BUILD"

    # Make init scripts executable
    chmod +x etc/init.d/rcS
    chmod +x etc/init.d/rcK

    # Set sticky bit on /tmp
    chmod 1777 tmp

    # Make root... root
    chmod 700 root

    print_step "Permissions set!"
}

finalize_rootfs() {
    print_step "Finalizing rootfs..."

    rm -rf "$ROOTFS_FINAL"
    mv "$ROOTFS_BUILD" "$ROOTFS_FINAL"

    print_step "Rootfs ready at: $ROOTFS_FINAL"
}

create_squashfs() {
    print_step "Creating squashfs image..."

    rm -f "$ROOTFS_SQUASHFS"
    mksquashfs "$ROOTFS_FINAL" "$ROOTFS_SQUASHFS" \
        -comp zstd \
        -Xcompression-level 1 \
        -b 256K \
        -force-uid 0 \
        -force-gid 0 \
        -noappend

    print_step "SquashFS image created at: $ROOTFS_SQUASHFS"
}

main() {
    print_step "MIROKI Rootfs Build"

    check_dependencies
    populate_rootfs
    install_libraries
    install_busybox
    install_alsa
    install_launcher
    install_emulators
    resolve_library_closure
    set_permissions
    finalize_rootfs
    create_squashfs

    print_step "MIROKI Rootfs Build Complete!"
    echo ""
    echo "Rootfs directory:"
    echo "  $ROOTFS_FINAL"
    echo "SquashFS image:"
    echo "  $ROOTFS_SQUASHFS"
}

main "$@"
