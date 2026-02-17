#!/bin/bash
# MIMIKI - Rootfs Build Script
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
CONFIG_DIR="$REPO_ROOT/system/config"
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
    mkdir -p "$ROOTFS_BUILD"/{bin,dev,etc,lib,root,mnt/games,mnt/games2,proc,run,sbin,sys,tmp,usr/bin,usr/lib,usr/share,usr/sbin,var}

    if [ -d "$ROOTFS_SKELETON" ]; then
        cp -a "$ROOTFS_SKELETON"/* "$ROOTFS_BUILD"/ 2>/dev/null || true
    fi

    print_step "Preliminary rootfs ready!"
}

install_launcher() {
    print_step "Installing Launcher..."

    if [ -f "$REPO_ROOT/system/launcher/build/mimiki-launcher" ]; then
        cp "$REPO_ROOT/system/launcher/build/mimiki-launcher" "$ROOTFS_BUILD/usr/bin/"
        chmod +x "$ROOTFS_BUILD/usr/bin/mimiki-launcher"
    else
        print_warning "Launcher not built! Run 'make launcher' first."
    fi

    local SDL2_INSTALL="$BUILD_DIR/sdl2-install"
    if [ -d "$SDL2_INSTALL/usr/share/mimiki" ]; then
        mkdir -p "$ROOTFS_BUILD/usr/share/mimiki"
        cp -a "$SDL2_INSTALL/usr/share/mimiki"/* "$ROOTFS_BUILD/usr/share/mimiki/"
        print_step "Launcher assets installed!"
    else
        print_warning "Launcher assets not found! Reggie... my dude..."
    fi

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

    # Additional libraries (GPU)
    mkdir -p "$ROOTFS_BUILD/usr/share/vulkan/icd.d"
    cp -a "$REPO_ROOT/system/prebuilts/libmali-blobs"/*.so* "$ROOTFS_BUILD/usr/lib/" || print_warning "Mali blobs not found"
    cp -a "$REPO_ROOT/system/prebuilts/libmali-blobs"/icd.d/*.json "$ROOTFS_BUILD/usr/share/vulkan/icd.d/" || print_warning "Vulkan icd not found"
    cp -a "$SYSROOT"/libdrm.so* "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libdrm not found"

    # Additional libraries (SDL2)
    local SDL2_INSTALL="$BUILD_DIR/sdl2-install"
    if [ -d "$SDL2_INSTALL/usr/lib" ]; then
        cp -a "$SDL2_INSTALL"/usr/lib/libSDL2*.so* "$ROOTFS_BUILD/usr/lib/"
    else
        print_warning "Custom SDL2 not found! Run 'make launcher' first."
    fi

    # Additional libraries (Emulators)
    # mupen64plus
    cp -L "$SYSROOT/libpng16.so.16" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libpng16 not found"
    cp -L "$SYSROOT/libz.so.1" "$ROOTFS_BUILD/usr/lib/" 2>/dev/null || print_warning "libz not found"
    # TODO: flycast
    # TODO: duckstation
    # TODO: ppsspp

    print_step "Libraries installed!"
}

install_kernel_modules() {
    print_step "Installing kernel modules..."

    if [ -d "$BUILD_DIR/rootfs/lib/modules" ]; then
        mkdir -p "$ROOTFS_BUILD/lib/modules"
        cp -a "$BUILD_DIR/rootfs/lib/modules"/* "$ROOTFS_BUILD/lib/modules/"

        # Remove development symlinks (build, source) that point to kernel source tree
        find "$ROOTFS_BUILD/lib/modules" -type l \( -name "build" -o -name "source" \) -delete

        print_step "Kernel modules installed!"
    else
        print_warning "No kernel modules found! Run 'make kernel' first."
    fi
}

install_emulators() {
    print_step "Installing emulators..."

    if [ -d "$BUILD_DIR/emulators/mupen64plus" ]; then
        mkdir -p "$ROOTFS_BUILD/root/.cache/mupen64plus"
        mkdir -p "$ROOTFS_BUILD/root/.local/share/mupen64plus"
        mkdir -p "$ROOTFS_BUILD/root/.config/mupen64plus/"{data,plugins}
        cp -a "$BUILD_DIR/emulators/mupen64plus/bin/mupen64plus" \
            "$ROOTFS_BUILD/usr/bin/"
        cp -a "$BUILD_DIR/emulators/mupen64plus/lib/libmupen64plus.so.2" \
            "$ROOTFS_BUILD/usr/lib/"
        cp -a "$BUILD_DIR/emulators/mupen64plus/lib/plugins"/* \
            "$ROOTFS_BUILD/root/.config/mupen64plus/plugins/"
        cp -a "$CONFIG_DIR/mupen64plus.cfg" \
            "$ROOTFS_BUILD/root/.config/mupen64plus/"
        cp -a "$CONFIG_DIR/InputAutoCfg.ini" \
            "$ROOTFS_BUILD/root/.config/mupen64plus/data/"

        print_step "mupen64plus installed!"
    fi

    print_step "Emulators installed!"
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
        -comp xz \
        -Xbcj arm \
        -b 1M \
        -force-uid 0 \
        -force-gid 0 \
        -noappend

    print_step "SquashFS image created at: $ROOTFS_SQUASHFS"
}

main() {
    print_step "MIMIKI Rootfs Build"

    check_dependencies
    populate_rootfs
    install_kernel_modules
    install_libraries
    install_busybox
    install_alsa
    install_launcher
    install_emulators
    set_permissions
    finalize_rootfs
    create_squashfs

    print_step "MIMIKI Rootfs Build Complete!"
    echo ""
    echo "Rootfs directory:"
    echo "  $ROOTFS_FINAL"
    echo "SquashFS image:"
    echo "  $ROOTFS_SQUASHFS"
}

main "$@"
