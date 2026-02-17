#!/bin/bash
# MIMIKI - Boot Build Script
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
UBOOT_DIR="$REPO_ROOT/external/boot/u-boot"
RKBIN_DIR="$REPO_ROOT/external/boot/rkbin"
INITRAMFS_DIR="$BUILD_DIR/initramfs"
TOOLS_DIR="$REPO_ROOT/external/tools"
KERNEL_DIR="$REPO_ROOT/external/boot/linux"
MALI_DIR="$REPO_ROOT/external/rocknix/mali_kbase/product/kernel/drivers/gpu/arm/midgard"
DT_SOURCE="$REPO_ROOT/system/dts/rk3566-miyoo-flip.dts"
DT_OVERLAYS_DIR="$REPO_ROOT/system/dts/overlays"
CONFIG_DIR="$REPO_ROOT/system/config"

# Build configuration
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
JOBS=$(nproc)

# Known good U-Boot configuration
UBOOT_DEFCONFIG="quartz64-a-rk3566_defconfig"
BL31="$RKBIN_DIR/bin/rk35/rk3568_bl31_v1.45.elf"
DDR_BIN="$RKBIN_DIR/bin/rk35/rk3566_ddr_1056MHz_v1.23.bin"

# Kernel version (will be detected in build)
KERNEL_VERSION=""

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

    for tool in bc bison flex make python3 swig; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done

    if ! python3 -c "import elftools" 2>/dev/null; then
        missing_deps+=("python3-pyelftools")
    fi

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
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,run,sys,dev,mnt,newroot,usr/sbin}

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

    # Check for marker
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

    # Create marker
    touch .patches_applied

    print_step "$component_name patches applied successfully!"
}

apply_all_patches() {
    apply_patches "U-Boot" "$UBOOT_DIR" "u-boot"
    apply_patches "kernel" "$KERNEL_DIR" "linux"
    apply_patches "Mali" "$MALI_DIR" "mali_kbase"
}

build_uboot() {
    print_step "Building U-Boot..."

    cd "$UBOOT_DIR"

    print_step "Using $UBOOT_DEFCONFIG as base..."
    make HOSTCC=gcc HOSTCFLAGS="-I/usr/include" $UBOOT_DEFCONFIG
    make -j${JOBS} \
        HOSTCC=gcc \
        HOSTCFLAGS="-I/usr/include" \
        CROSS_COMPILE="${CROSS_COMPILE}" \
        BL31="$BL31" \
        ROCKCHIP_TPL="$DDR_BIN" \
        all

    print_step "U-Boot built successfully!"
}

install_uboot() {
    print_step "Installing bootloader binaries..."

    mkdir -p "$BUILD_DIR/boot"

    cd "$UBOOT_DIR"

    # Copy separate bootloader components (needed for correct offset flashing)
    if [ -f "idbloader.img" ] && [ -f "u-boot.itb" ]; then
        cp idbloader.img "$BUILD_DIR/boot/"
        cp u-boot.itb "$BUILD_DIR/boot/"
        print_step "  idbloader.img copied"
        print_step "  u-boot.itb copied"
    else
        print_error "idbloader.img or u-boot.itb not found! Build may have failed"
        exit 1
    fi

    print_step "Bootloader binaries installed to $BUILD_DIR/boot/"
}

configure_kernel() {
    local DT_DEST="$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
    local MAKEFILE="$DT_DEST/Makefile"

    print_step "Configuring kernel..."

    cd "$KERNEL_DIR"

    # Apply MIMIKI config
    if [ -f "$CONFIG_DIR/mimiki.config" ]; then
        cp "$CONFIG_DIR/mimiki.config" .config
    else
        print_error "MIMIKI config not found at $CONFIG_DIR/mimiki.config"
        exit 1
    fi

    # Integrate device tree
    if [ -f "$DT_SOURCE" ]; then
        cp "$DT_SOURCE" "$DT_DEST/"
        print_step "Copied rk3566-miyoo-flip.dts to kernel tree"
    else
        print_error "Device tree source not found at $DT_SOURCE"
        exit 1
    fi

    # Add to Makefile if not already there
    if ! grep -q "rk3566-miyoo-flip.dtb" "$MAKEFILE"; then
        echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += rk3566-miyoo-flip.dtb" >> "$MAKEFILE"
        print_step "Added rk3566-miyoo-flip.dtb to Makefile"
    fi
}

build_kernel() {
    print_step "Building kernel..."

    cd "$KERNEL_DIR"

    # Build kernel artifacts
    make -j${JOBS} Image
    make -j${JOBS} modules
    make -j${JOBS} rockchip/rk3566-miyoo-flip.dtb
    mkdir -p "$BUILD_DIR/dt-overlays"
    for overlay in "$DT_OVERLAYS_DIR"/*.dts; do
        if [ -f "$overlay" ]; then
            local overlay_name=$(basename "$overlay" .dts)
            print_step "  Building $overlay_name..."
            dtc -@ -I dts -O dtb -o "$BUILD_DIR/dt-overlays/${overlay_name}.dtbo" "$overlay"
        fi
    done

    # Get version for later
    KERNEL_VERSION=$(make -s --no-print-directory kernelrelease)

    print_step "Kernel built!"
}

install_int_modules() {
    print_step "Installing modules to build directory..."

    cd "$KERNEL_DIR"

    mkdir -p "$BUILD_DIR/rootfs"
    make -j${JOBS} INSTALL_MOD_PATH="$BUILD_DIR/rootfs" modules_install

    # Strip modules to save space
    find "$BUILD_DIR/rootfs/lib/modules" -name "*.ko" -exec ${CROSS_COMPILE}strip --strip-unneeded {} \;

    print_step "Modules installed!"
}

build_out_of_tree_module() {
    local module_name="$1"
    local module_dir="$2"
    local module_ko="$3"
    shift 3
    local make_args=("$@")

    print_step "Building $module_name..."

    if [ ! -d "$module_dir" ]; then
        print_warning "$module_name source not found at $module_dir, skipping..."
        return 0
    fi

    cd "$module_dir"

    make -j${JOBS} ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} "${make_args[@]}"

    if [ $? -eq 0 ]; then
        if [ -n "$KERNEL_VERSION" ]; then
            if [ -f "$module_dir/$module_ko" ]; then
                local MODULE_DIR="$BUILD_DIR/rootfs/lib/modules/$KERNEL_VERSION/extra"
                mkdir -p "$MODULE_DIR"

                cp "$module_dir/$module_ko" "$MODULE_DIR/"
                ${CROSS_COMPILE}strip --strip-unneeded "$MODULE_DIR/$module_ko"

                print_step "$module_name built and installed!"
            else
                print_warning "$module_name module file $module_ko not found after build"
                return 1
            fi
        fi
    else
        print_warning "$module_name build failed, skipping..."
        return 1
    fi
}

build_ext_modules() {
    build_out_of_tree_module \
        "Mali GPU driver" \
        "$MALI_DIR" \
        "mali_kbase.ko" \
        KDIR="$KERNEL_DIR" \
        CONFIG_MALI_MIDGARD=m \
        CONFIG_MALI_PLATFORM_NAME=meson \
        CONFIG_MALI_REAL_HW=y \
        CONFIG_MALI_DEVFREQ=y \
        CONFIG_MALI_GATOR_SUPPORT=y

    build_out_of_tree_module \
        "ROCKNIX joypad driver" \
        "$REPO_ROOT/external/rocknix/rocknix-joypad" \
        "rocknix-singleadc-joypad.ko" \
        KERNEL_SRC="$KERNEL_DIR" \
        DEVICE="RK3566"

    build_out_of_tree_module \
        "Generic DSI panel driver" \
        "$REPO_ROOT/external/rocknix/generic-dsi" \
        "panel-generic-dsi.ko" \
        KERNEL_SRC="$KERNEL_DIR"
}

install_kernel() {
    print_step "Installing kernel to $BUILD_DIR/boot/..."

    mkdir -p "$BUILD_DIR/boot"

    cp "$KERNEL_DIR/arch/arm64/boot/Image" "$BUILD_DIR/boot/"
    cp "$KERNEL_DIR/arch/arm64/boot/dts/rockchip/rk3566-miyoo-flip.dtb" "$BUILD_DIR/boot/"
}

main() {
    echo -e "${GREEN}MIMIKI Kernel Build${NC}"

    check_dependencies
    populate_initramfs
    copy_libraries
    apply_all_patches
    build_uboot
    install_uboot
    configure_kernel
    build_kernel
    install_int_modules
    build_ext_modules
    install_kernel

    echo "MIMIKI Kernel Build Complete!"
    echo ""
    echo "Build artifacts:"
    echo "  Kernel:  $BUILD_DIR/boot/Image"
    echo "  DTB:     $BUILD_DIR/boot/rk3566-miyoo-flip.dtb"
    echo "  Overlays: $BUILD_DIR/dt-overlays/"
    echo "  Modules: $BUILD_DIR/rootfs/lib/modules/$KERNEL_VERSION/"
}

main "$@"
