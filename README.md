# MIMIKI - Minimal Miyoo Kiosk

A minimal, RetroArch-based emulation platform for the Miyoo Flip (RK3566). MIMIKI provides a lightweight Linux OS image with a custom SDL2 launcher and pre-configured emulation cores for N64, Dreamcast, PS1, and PSP.

---

## Requirements

- Linux host with standard build tools (`gcc`, `make`, `git`, `parted`, `dd`)
- ARM64 cross-compiler (`aarch64-linux-gnu-gcc`)
- Root access for image creation and flashing
- GammaLoader installed in stock firmware

---

## Cloning

The project uses Git submodules for the kernel, bootloader, libraries, and emulation cores. Clone with all submodules in one step:

```sh
git clone --recurse-submodules https://github.com/noxwell/mimiki.git
cd mimiki
```

If you have already cloned without `--recurse-submodules`, initialize the submodules manually:

```sh
git submodule update --init --recursive
```
NOTE: The mupen64plus directory may throw an error here. If so, you will need to initialize each other submodule manually rather than recursively.

---

## Build System

Run `make help` to display all available build targets:

```sh
make help
```

The standard build sequence is:

```sh
make tools        # Build libraries and utilities (SDL2, busybox, etc.)
make boot         # Build U-Boot and Linux kernel
make launcher     # Build the MIMIKI SDL2 launcher
make retroarch    # Build RetroArch and emulation cores
make rootfs       # Assemble the root filesystem
make image        # Create a bootable SD card image (requires root)
```

Or build everything in one command:

```sh
make build-all
```

---

## Flashing

Once the image is built, flash it to an SD card:

```sh
make flash SDCARD=/dev/sdX
```

Replace `/dev/sdX` with the actual block device path of your SD card. This operation requires root and will **overwrite all data** on the target device.

Or use your preferred image flashing program with a pre-built image from Releases.

---

## SD Card Setup

The Miyoo Flip has two SD card slots. MIMIKI supports both single and dual SD card configurations.

### Single SD Card

Place the MIMIKI system image in **SD slot 1 (Right Side Slot under Power Button)**. ROMs and game assets are stored on the same card under the appropriate directories. This is the simplest setup and works out of the box.

```
SD Slot 1: MIMIKI system image + games
SD Slot 2: (unused)
```

### Two SD Cards

For expanded storage, a second SD card can be added to **SD slot 2**.
MIMIKI will automatically mount it at `/mnt/games2`, and files will be propagated as needed.

```
SD Slot 1: MIMIKI system image (boot + root) + primary game storage (/mnt/games)
SD Slot 2: Additional game storage (/mnt/games2)
```

Format the second card as exFAT or FAT32 before use.

### Game Directory Structure

Create the following directories on your SD card(s) and place your ROMs inside. The launcher scans these directories automatically on boot.

| Directory | System      | Supported Formats               | Notes                                |
|-----------|-------------|---------------------------------|--------------------------------------|
| `/n64`    | Nintendo 64 | `.z64`, `.n64`, `.v64`          |                                      |
| `/dc`     | Dreamcast   | `.chd`, `.gdi`, `.cdi`          | BIOS files required under `/bios/dc` |
| `/ps1`    | PlayStation | `.chd`, `.pbp`, `.bin`/`.cue`   | BIOS files required under `/bios`    |
| `/psp`    | PSP         | `.chd`, `.cso`, `.iso`          |                                      |

These same directories can be created on a second SD card, the launcher will scan both cards on boot.

---

## Supported Emulation Cores

| System      | Core                    |
|-------------|-------------------------|
| N64         | mupen64plus-libretro-nx |
| Dreamcast   | Flycast                 |
| PlayStation | PCSX ReARMed            |
| PSP         | PPSSPP                  |

---

## System-wide Hotkeys

| Key Combo | Effect                        |
|-----------|-------------------------------|
| M + Start | Exit to Menu                  |
| M + R3    | Save State                    |
| M + L3    | Load State                    |
| M + VolUp | Brightness Up                 |
| M + VolDn | Brightness Down               |
| Lid       | Sleep/Wake                    |
| Tap Pwr   | Sleep/Wake                    |
| Hold Pwr  | Exit+Pwroff (!DOES NOT SAVE!) |
