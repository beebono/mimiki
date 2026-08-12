#!/bin/bash
# MIMIKI - Boot Build Script (RG Rotate / Unisoc UMS512 T618)
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
UBOOT_DIR="$REPO_ROOT/external/base/u-boot"
KERNEL_DIR="$REPO_ROOT/external/base/linux"
MALI_DIR="$REPO_ROOT/external/base/mali-kbase"
INITRAMFS_DIR="$BUILD_DIR/initramfs"
TOOLS_DIR="$REPO_ROOT/external/tools"
FIRMWARE_DIR="$REPO_ROOT/system/prebuilts/firmware"
CONFIG_DIR="$REPO_ROOT/system/config"

# Build configuration
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
JOBS=$(nproc)

# The vendor U-Boot is 32-bit-style vendor code: it builds under ARCH=arm with
# the aarch64 toolchain, and the board is selected via DEVICE_TREE.
UBOOT_DEFCONFIG="ums512_rg_rotate_defconfig"
UBOOT_DEVICE_TREE="ums512_rg_rotate"
# Newer GCC hates this older vendor code; known-working on device, so just
# downgrade the warnings and set an older std to make it build.
UBOOT_KCFLAGS="-std=gnu11 \
    -Wno-error=implicit-int \
    -Wno-error=implicit-function-declaration \
    -Wno-error=int-conversion \
    -Wno-error=incompatible-pointer-types \
    -Wno-error=return-mismatch"

DTB_NAME="ums512-rg-rotate"

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
        missing_deps+=("aarch64-linux-gnu-gcc")
    fi

    if ! command -v dtc &> /dev/null; then
        missing_deps+=("device-tree-compiler")
    fi

    for tool in bc bison flex make python3; do
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

populate_initramfs() {
    print_step "Populating initramfs directory structure..."

    if [ -d "$INITRAMFS_DIR" ]; then
        rm -r "$INITRAMFS_DIR"
    fi
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,run,sys,dev,mnt,newroot,usr/sbin,lib/firmware}

    if [ -f "$TOOLS_DIR/busybox/busybox" ]; then
        cp "$TOOLS_DIR/busybox/busybox" "$INITRAMFS_DIR/bin/"
        chmod +x "$INITRAMFS_DIR/bin/busybox"

        # Install busybox symlinks for essential applets needed in initramfs
        cd "$INITRAMFS_DIR/bin"
        for applet in sh ash mount umount switch_root mdev mkdir mknod chmod cp ln cat dmesg echo; do
            ln -sf busybox "$applet"
        done
        cd "$REPO_ROOT"

        print_step "  Busybox installed to initramfs"
    else
        print_error "Busybox binary not found at $TOOLS_DIR/busybox/busybox"
        print_error "Please run 'make tools' first!"
        exit 1
    fi

    if [ -f "$TOOLS_DIR/gptfdisk/sgdisk" ]; then
        cp "$TOOLS_DIR/gptfdisk/sgdisk" "$INITRAMFS_DIR/sbin/"
        chmod +x "$INITRAMFS_DIR/sbin/sgdisk"
        print_step "  sgdisk installed to initramfs"
    else
        print_error "sgdisk binary not found at $TOOLS_DIR/gptfdisk/sgdisk"
        print_error "Please run 'make tools' first!"
        exit 1
    fi

    if [ -f "$TOOLS_DIR/exfatprogs/build/mkfs/mkfs.exfat" ]; then
        cp "$TOOLS_DIR/exfatprogs/build/mkfs/mkfs.exfat" "$INITRAMFS_DIR/usr/sbin/"
        chmod +x "$INITRAMFS_DIR/usr/sbin/mkfs.exfat"
        print_step "  mkfs.exfat installed to initramfs"
    else
        print_error "mkfs.exfat binary not found at $TOOLS_DIR/exfatprogs/build/mkfs/mkfs.exfat"
        print_error "Please run 'make tools' first!"
        exit 1
    fi

    cp "$REPO_ROOT/system/initramfs/init" "$INITRAMFS_DIR/"
    chmod +x "$INITRAMFS_DIR/init"

    print_step "Initramfs directory structure ready!"
}

copy_libraries() {
    print_step "Copying required libraries..."

    mkdir -p "$INITRAMFS_DIR/lib"

    local sysroot="/usr/lib/aarch64-linux-gnu"

    if [ -f "$sysroot/libc.so.6" ]; then
        cp -a "$sysroot/libc.so.6" "$INITRAMFS_DIR/lib/" 2>/dev/null || true
    fi
    if [ -f "$sysroot/ld-linux-aarch64.so.1" ]; then
        cp -a "$sysroot/ld-linux-aarch64.so.1" "$INITRAMFS_DIR/lib/" 2>/dev/null || true
    fi

    print_step "Libraries copied!"
}

apply_patches() {
    local component_name="$1"
    local target_dir="$2"
    local patch_subdir="$3"

    print_step "Applying $component_name patches..."

    local PATCHES_DIR="$REPO_ROOT/system/patches/$patch_subdir"

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
    apply_patches "U-Boot" "$UBOOT_DIR" "u-boot"
    apply_patches "kernel" "$KERNEL_DIR" "linux"
    apply_patches "Mali" "$MALI_DIR" "mali-kbase"
}

build_uboot() {
    print_step "Building U-Boot..."

    cd "$UBOOT_DIR"

    print_step "Using $UBOOT_DEFCONFIG as base..."
    make ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" \
        DEVICE_TREE="$UBOOT_DEVICE_TREE" \
        HOSTCC=gcc $UBOOT_DEFCONFIG
    make -j${JOBS} ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" \
        DEVICE_TREE="$UBOOT_DEVICE_TREE" \
        KCFLAGS="$UBOOT_KCFLAGS" \
        HOSTCC=gcc u-boot-dtb.bin

    print_step "U-Boot built successfully!"
}

install_uboot() {
    print_step "Packing and installing bootloader binary..."

    mkdir -p "$BUILD_DIR/boot"

    cd "$UBOOT_DIR"

    if [ ! -f "u-boot-dtb.bin" ]; then
        print_error "u-boot-dtb.bin not found! Build may have failed"
        exit 1
    fi

    # The SPL loads U-Boot from the SD card's GPT partition named "uboot" as a
    # DHTB image: 512-byte header (magic + SHA256 + payload length) followed by
    # the payload. It must stay under the SPL's 1 MiB limit; pad to exactly the
    # image size so we don't write sectors past the payload.
    local payload_size dhtb_size
    payload_size=$(stat -c%s "u-boot-dtb.bin")
    dhtb_size=$((payload_size + 512))

    if [ $dhtb_size -gt $((1024 * 1024)) ]; then
        print_error "DHTB image ($dhtb_size bytes) exceeds the SPL's 1 MiB limit"
        exit 1
    fi

    python3 "$REPO_ROOT/scripts/dhtb_pack.py" u-boot-dtb.bin "$BUILD_DIR/boot/uboot.bin" $dhtb_size
    print_step "  uboot.bin (DHTB) installed"

    print_step "Bootloader binary installed to $BUILD_DIR/boot/"
}

configure_kernel() {
    print_step "Configuring kernel..."

    cd "$KERNEL_DIR"

    if [ -f "$CONFIG_DIR/mimiki.config" ]; then
        cp "$CONFIG_DIR/mimiki.config" .config
    else
        print_error "MIMIKI config not found at $CONFIG_DIR/mimiki.config"
        exit 1
    fi
}

build_kernel() {
    print_step "Building kernel..."

    cd "$KERNEL_DIR"

    make -j${JOBS} Image
    make -j${JOBS} sprd/${DTB_NAME}.dtb
    make -j${JOBS} modules

    # In-tree modules (audio DSP boot is deferred to rcS so its firmware can
    # live in the squashfs instead of the initramfs)
    mkdir -p "$BUILD_DIR/modules"
    cp drivers/soc/sprd/sprd-audcp-boot.ko "$BUILD_DIR/modules/"

    print_step "Kernel built!"
}

build_mali_kbase() {
    print_step "Building mali_kbase module..."

    make -j${JOBS} -C "$MALI_DIR/product/kernel/drivers/gpu/arm/midgard" KDIR="$KERNEL_DIR" \
        CONFIG_MALI_MIDGARD=m \
        CONFIG_MALI_PLATFORM_NAME=devicetree \
        CONFIG_MALI_REAL_HW=y \
        CONFIG_MALI_DEVFREQ=y \
        CONFIG_MALI_GATOR_SUPPORT=y

    local KBASE_KO="$MALI_DIR/product/kernel/drivers/gpu/arm/midgard/mali_kbase.ko"
    if [ ! -f "$KBASE_KO" ]; then
        print_error "mali_kbase.ko not found! Build may have failed"
        exit 1
    fi

    mkdir -p "$BUILD_DIR/modules"
    cp "$KBASE_KO" "$BUILD_DIR/modules/"

    print_step "mali_kbase.ko installed to $BUILD_DIR/modules/"
}

install_kernel() {
    print_step "Installing kernel to $BUILD_DIR/boot/..."

    mkdir -p "$BUILD_DIR/boot"

    cp "$KERNEL_DIR/arch/arm64/boot/Image" "$BUILD_DIR/boot/"
    cp "$KERNEL_DIR/arch/arm64/boot/dts/sprd/${DTB_NAME}.dtb" "$BUILD_DIR/boot/"
}

main() {
    echo -e "${GREEN}MIMIKI Boot Build${NC}"

    check_dependencies
    populate_initramfs
    copy_libraries
    apply_all_patches
    build_uboot
    install_uboot
    configure_kernel
    build_kernel
    build_mali_kbase
    install_kernel

    echo "MIMIKI Boot Build Complete!"
    echo ""
    echo "Build artifacts:"
    echo "  U-Boot:  $BUILD_DIR/boot/uboot.bin (DHTB, SPL-loadable)"
    echo "  Kernel:  $BUILD_DIR/boot/Image"
    echo "  DTB:     $BUILD_DIR/boot/${DTB_NAME}.dtb"
    echo "  Modules: $BUILD_DIR/modules/mali_kbase.ko"
}

main "$@"
