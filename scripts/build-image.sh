#!/bin/bash
# MIMIKI - SD Card Image Creation Script (RG Rotate / Unisoc UMS512 T618)
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

# Root size auto calculation (round up to next MiB)
ROOTFS_SIZE=$(stat -c%s "$ROOTFS_SQUASHFS")

# Partition sizes (in MB)
# The SPL finds U-Boot by scanning the SD card's GPT for a partition literally
# named "uboot" (checked before the eMMC uboot_a/b slots, so it wins over the
# stock u-boot). The DHTB payload is capped at 1MiB but keep some headroom.
UBOOT_SIZE_MB=8
BOOT_SIZE_MB=32
ROOT_SIZE_MB=$(( (ROOTFS_SIZE + 1048575) / 1048576 ))
if [ $ROOT_SIZE_MB -lt 32 ]; then
    ROOT_SIZE_MB=32
fi

# Total Size (partition table padding at end)
IMAGE_SIZE_MB=$((1 + UBOOT_SIZE_MB + BOOT_SIZE_MB + ROOT_SIZE_MB + 2))

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

    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root for loop device mounting"
        exit 1
    fi

    local missing_tools=()
    for tool in dd parted mkfs.vfat losetup; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
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

    print_step "Prerequisites check passed!"
}

create_image_file() {
    print_step "Creating blank image file ($IMAGE_SIZE_MB MB)..."

    mkdir -p "$OUTPUT_DIR"
    local image_path="$OUTPUT_DIR/mimiki-sdcard.img"
    dd if=/dev/zero of="$image_path" bs=1M count=0 seek=$IMAGE_SIZE_MB status=none

    echo "$image_path"
}

create_partitions() {
    local image_path="$1"

    # 1MiB alignment gap up front for the primary GPT
    local uboot_start=1
    local uboot_end=$((uboot_start + UBOOT_SIZE_MB))
    local boot_start=$uboot_end
    local boot_end=$((boot_start + BOOT_SIZE_MB))
    local root_start=$boot_end
    local root_end=$((root_start + ROOT_SIZE_MB))

    print_step "Creating partition table..."
    parted -s "$image_path" mklabel gpt
    print_step "Creating uboot partition (${UBOOT_SIZE_MB}MB, GPT name 'uboot')..."
    parted -s "$image_path" mkpart uboot ${uboot_start}MiB ${uboot_end}MiB
    print_step "Creating boot partition (${BOOT_SIZE_MB}MB, GPT name 'vfat')..."
    parted -s "$image_path" mkpart vfat fat32 ${boot_start}MiB ${boot_end}MiB
    print_step "Setting ESP flag on boot partition for U-Boot detection..."
    parted -s "$image_path" set 2 esp on
    print_step "Creating root partition (${ROOT_SIZE_MB}MB, GPT name 'rootfs')..."
    parted -s "$image_path" mkpart rootfs ${root_start}MiB ${root_end}MiB
    sync
    parted -s "$image_path" print
}

setup_loop_device() {
    local image_path="$1"

    print_step "Setting up loop device..."
    local loop_dev=$(losetup -f --show -P "$image_path")

    if [ -z "$loop_dev" ]; then
        print_error "Failed to create loop device"
        exit 1
    fi

    sleep 2
    partprobe "$loop_dev" 2>/dev/null || true
    sleep 1

    echo "$loop_dev"
}

write_uboot_to_partition() {
    local loop_dev="$1"

    print_step "Writing uboot.bin to uboot partition (raw)..."

    # The SPL loads the DHTB-wrapped U-Boot from the GPT partition named "uboot"
    dd if="$BOOTLOADER_DIR/uboot.bin" \
       of="${loop_dev}p1" \
       bs=4M \
       conv=fsync \
       status=none

    print_step "uboot.bin written to uboot partition!"
}

format_boot_partition() {
    local loop_dev="$1"

    print_step "Formatting boot partition..."

    # Calculate partition size in 1KB blocks for mkfs.vfat
    local part_size_bytes=$(blockdev --getsize64 "${loop_dev}p2")
    local part_size_kb=$((part_size_bytes / 1024))
    mkfs.vfat -F 32 -n MIMIKI "${loop_dev}p2" $part_size_kb

    print_step "Boot partition formatted successfully!"
}

populate_boot_partition() {
    local loop_dev="$1"

    print_step "Populating boot partition..."

    local mount_point=$(mktemp -d)
    mount "${loop_dev}p2" "$mount_point"

    ls -lh "$BUILD_DIR/boot/Image"
    cp "$BUILD_DIR/boot/Image" "$mount_point/"
    cp "$BUILD_DIR/boot/${DTB_NAME}.dtb" "$mount_point/"

    print_step "Creating EXTLINUX boot configuration..."
    mkdir -p "$mount_point/extlinux"
    cat > "$mount_point/extlinux/extlinux.conf" <<EOF
LABEL MIMIKI
  KERNEL /Image
  FDT /${DTB_NAME}.dtb
  APPEND rootwait quiet loglevel=0 fbcon=font:TER16x32
EOF

    sync
    umount "$mount_point"
    rmdir "$mount_point"

    print_step "Boot partition populated!"
}

write_squashfs_to_partition() {
    local loop_dev="$1"

    print_step "Writing rootfs.squashfs to rootfs partition (raw)..."
    dd if="$ROOTFS_SQUASHFS" \
       of="${loop_dev}p3" \
       bs=4M \
       conv=fsync \
       status=none

    print_step "rootfs.squashfs written to rootfs partition!"
}

cleanup_loop_device() {
    print_step "Cleaning up loop device..."
    losetup -D 2>/dev/null || true
}

main() {
    print_step "MIMIKI SD Card Image Creation"

    check_prerequisites
    local image_path=$(create_image_file)
    print_step "Image file: $image_path"
    create_partitions "$image_path"
    local loop_dev=$(setup_loop_device "$image_path")
    print_step "Loop device: $loop_dev"
    write_uboot_to_partition "$loop_dev"
    format_boot_partition "$loop_dev"
    populate_boot_partition "$loop_dev"
    write_squashfs_to_partition "$loop_dev"
    cleanup_loop_device "$loop_dev"

    # Chmod the build directory so it can be easily read or cleaned up later
    chmod -R a+rw "$BUILD_DIR"

    print_step "SD card image created successfully!"
    echo "Output: $image_path"
    echo "Written Size: $(du --apparent-size -h "$image_path" | cut -f1)"
    echo "Logical Size: $(du -h "$image_path" | cut -f1)"
    echo ""
    echo "To flash to SD card:"
    echo "  make flash SDCARD=/dev/sdX"
    echo ""
    print_warning "Make sure to replace /dev/sdX with your actual SD card device!"
}

# No danglers!
trap 'cleanup_loop_device "$loop_dev" 2>/dev/null || true' EXIT

main "$@"
