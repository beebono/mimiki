#!/bin/bash
# MIROKI - SD Card Image Creation Script (RG Rotate / Unisoc UMS512 T618)
#
# Fully unprivileged: the FAT boot filesystem is built as a plain file with
# mkfs.vfat + mtools, the GPT is written with sfdisk on a regular file, and
# the raw u-boot/squashfs images are dd'd into their partition offsets.
# No loop devices, no root, no sudo.
#
# Layout (the SPL finds U-Boot by scanning the SD GPT for a partition
# literally named "uboot", ahead of the eMMC uboot_a/b slots):
#   p1 = raw "uboot"  -> uboot.bin (DHTB)
#   p2 = FAT32 boot   -> /extlinux/extlinux.conf + /Image + /<dtb>
#   p3 = squashfs     -> MIROKI rootfs
#   p4 = games        -> created on-device by the initramfs (sgdisk -e -N 4)
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
BOOTLOADER_DIR="$BUILD_DIR/boot"
ROOTFS_SQUASHFS="$BUILD_DIR/rootfs.squashfs"
OUTPUT_DIR="$BUILD_DIR/images"

DTB_NAME="ums512-rg-rotate"

MiB=1048576

# Partition sizes (in MB)
UBOOT_SIZE_MB=8
BOOT_SIZE_MB=32

print_step() {
    echo -e "${GREEN}==>${NC} $1" >&2
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1" >&2
}

check_prerequisites() {
    print_step "Checking prerequisites..."

    local missing_tools=()
    for tool in dd sfdisk mkfs.vfat mmd mcopy truncate stat; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_error "(mmd/mcopy come from the 'mtools' package)"
        exit 1
    fi

    if [ ! -f "$BOOTLOADER_DIR/uboot.bin" ]; then
        print_error "Bootloader binary not found! Run 'make boot' first"
        print_error "Expected: $BOOTLOADER_DIR/uboot.bin"
        exit 1
    fi

    if [ ! -f "$BUILD_DIR/boot/Image" ]; then
        print_error "Kernel not found! Run 'make boot' first"
        exit 1
    fi

    if [ ! -f "$BUILD_DIR/boot/${DTB_NAME}.dtb" ]; then
        print_error "Device tree not found! Run 'make boot' first"
        exit 1
    fi

    if [ ! -f "$ROOTFS_SQUASHFS" ]; then
        print_error "Rootfs squashfs not found! Run 'make rootfs' first"
        print_error "Expected: $ROOTFS_SQUASHFS"
        exit 1
    fi

    local uboot_bytes
    uboot_bytes=$(stat -c%s "$BOOTLOADER_DIR/uboot.bin")
    if [ "$uboot_bytes" -gt $((UBOOT_SIZE_MB * MiB)) ]; then
        print_error "uboot.bin ($uboot_bytes bytes) exceeds the uboot partition (${UBOOT_SIZE_MB}MiB)"
        exit 1
    fi

    print_step "Prerequisites check passed!"
}

main() {
    print_step "MIROKI SD Card Image Creation"

    check_prerequisites

    # Root size auto calculation (round up to next MiB)
    local rootfs_size root_size_mb
    rootfs_size=$(stat -c%s "$ROOTFS_SQUASHFS")
    root_size_mb=$(( (rootfs_size + MiB - 1) / MiB ))
    if [ $root_size_mb -lt 32 ]; then
        root_size_mb=32
    fi

    # 1MiB alignment gap up front (primary GPT), 1MiB tail (backup GPT)
    local uboot_start=1
    local boot_start=$((uboot_start + UBOOT_SIZE_MB))
    local root_start=$((boot_start + BOOT_SIZE_MB))
    local image_size_mb=$((root_start + root_size_mb + 1))

    mkdir -p "$OUTPUT_DIR"
    local image_path="$OUTPUT_DIR/miroki-sdcard.img"
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    # ------------------------------------------------------------------
    # 1. Boot filesystem (FAT32) as a plain file
    # ------------------------------------------------------------------
    print_step "Building boot filesystem (${BOOT_SIZE_MB}MB FAT32)..."
    local boot_img="$tmpdir/boot.img"
    truncate -s $((BOOT_SIZE_MB * MiB)) "$boot_img"
    mkfs.vfat -F 32 -n MIROKI "$boot_img" > /dev/null

    cat > "$tmpdir/extlinux.conf" <<EOF
LABEL MIROKI
  KERNEL /Image
  FDT /${DTB_NAME}.dtb
  APPEND rootwait quiet loglevel=0 fbcon=font:TER16x32 vt.global_cursor_default=0
EOF

    mmd   -i "$boot_img" ::/extlinux
    mcopy -i "$boot_img" "$BUILD_DIR/boot/Image"           "::/Image"
    mcopy -i "$boot_img" "$BUILD_DIR/boot/${DTB_NAME}.dtb" "::/${DTB_NAME}.dtb"
    mcopy -i "$boot_img" "$tmpdir/extlinux.conf"           "::/extlinux/extlinux.conf"
    print_step "Boot filesystem built!"

    # ------------------------------------------------------------------
    # 2. Whole-disk image: GPT + dd everything into its offsets
    # ------------------------------------------------------------------
    print_step "Creating image file (${image_size_mb}MB)..."
    rm -f "$image_path"
    truncate -s $((image_size_mb * MiB)) "$image_path"

    print_step "Writing partition table..."
    # Named partitions: the SPL locates U-Boot by the GPT name "uboot";
    # the boot partition carries the ESP type GUID for U-Boot's extlinux scan.
    local GUID_RAW="21686148-6449-6E6F-744E-656564454649"   # raw bootloader
    local GUID_ESP="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"   # EFI System (FAT)
    local GUID_LINUX="0FC63DAF-8483-4772-8E79-3D69D8477DE4" # Linux filesystem
    sfdisk "$image_path" > /dev/null <<EOF
label: gpt
unit: sectors
sector-size: 512
start=$((uboot_start * MiB / 512)), size=$((UBOOT_SIZE_MB * MiB / 512)), type=$GUID_RAW,   name="uboot"
start=$((boot_start * MiB / 512)),  size=$((BOOT_SIZE_MB * MiB / 512)),  type=$GUID_ESP,   name="vfat"
start=$((root_start * MiB / 512)),  size=$((root_size_mb * MiB / 512)),  type=$GUID_LINUX, name="rootfs"
EOF

    print_step "Writing uboot.bin (DHTB) into uboot partition..."
    dd if="$BOOTLOADER_DIR/uboot.bin" of="$image_path" bs=1M seek=$uboot_start conv=notrunc status=none

    print_step "Writing boot filesystem..."
    dd if="$boot_img" of="$image_path" bs=1M seek=$boot_start conv=notrunc status=none

    print_step "Writing rootfs.squashfs..."
    dd if="$ROOTFS_SQUASHFS" of="$image_path" bs=1M seek=$root_start conv=notrunc status=none

    print_step "SD card image created successfully!"
    echo "Output: $image_path"
    echo "Written Size: $(du --apparent-size -h "$image_path" | cut -f1)"
    echo "Logical Size: $(du -h "$image_path" | cut -f1)"
    echo ""
    echo "Partition table:"
    sfdisk -d "$image_path" 2>/dev/null | sed 's/^/  /'
    echo ""
    echo "To flash to SD card:"
    echo "  make flash SDCARD=/dev/sdX"
    echo ""
    print_warning "Make sure to replace /dev/sdX with your actual SD card device!"
}

main "$@"
