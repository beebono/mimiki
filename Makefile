# MIMIKI - Minimal Miyoo Kiosk
# Top-level Makefile

.PHONY: all help tools boot launcher emulators rootfs build-all image flash clean clean-all

BUILD_DIR := build
SCRIPTS_DIR := scripts

# Message formatting
MSG_INFO = @echo "\033[1;34m==>\033[0m \033[1m$(1)\033[0m"
MSG_SUCCESS = @echo "\033[1;32m==>\033[0m \033[1m$(1)\033[0m"
MSG_WARNING = @echo "\033[1;33m==>\033[0m \033[1m$(1)\033[0m"
MSG_ERROR = @echo "\033[1;31m==>\033[0m \033[1m$(1)\033[0m"

all: help

help:
	@echo "MIMIKI Make System"
	@echo ""
	@echo "Build targets:"
	@echo "  make tools        - Build libraries and utilities"
	@echo "  make boot         - Build boot essentials"
	@echo "  make launcher     - Build MIMIKI SDL2 launcher"
	@echo "  make emulators    - Build all emulators"
	@echo "  make rootfs       - Build minimal RootFS"
	@echo "  make build-all    - Build all of the above"
	@echo ""
	@echo "Image targets (Needs Root):"
	@echo "  make image                  - Create bootable SD card image"
	@echo "  make flash SDCARD=/dev/sdX  - Flash image to SD card"
	@echo ""
	@echo "Clean targets:"
	@echo "  make clean        - Clean build directory"
	@echo "  make clean-all    - Clean EVERYTHING"
	@echo ""	

tools:
	$(call MSG_INFO,Building Tools...)
	@$(SCRIPTS_DIR)/build-tools.sh

boot:
	$(call MSG_INFO,Building Boot...)
	@$(SCRIPTS_DIR)/build-boot.sh

launcher:
	$(call MSG_INFO,Building Launcher...)
	@$(SCRIPTS_DIR)/build-launcher.sh

emulators:
	$(call MSG_INFO,Building Emulators...)
	@$(SCRIPTS_DIR)/build-emulators.sh

rootfs:
	$(call MSG_INFO,Building RootFS...)
	@$(SCRIPTS_DIR)/build-rootfs.sh

build-all: tools boot launcher emulators rootfs
	$(call MSG_SUCCESS,All targets built!)

image:
	$(call MSG_INFO,Creating SD card image...)
	@$(SCRIPTS_DIR)/build-image.sh

flash:
ifneq ($(shell id -u), 0)
	$(error This target needs to be run with root privleges to write the image)
endif
ifndef SDCARD
	$(error SDCARD device needs to be defined. Use 'make flash SDCARD=/dev/sdX' with root priveleges)
endif
ifeq ($(wildcard $(BUILD_DIR)/images/mimiki-sdcard.img),)
	$(error No mimiki-sdcard.img found in './build/images/'. Run 'make image' first)
endif
	$(call MSG_WARNING,This will erase $(SDCARD)!)
	$(call MSG_WARNING,All data on $(SDCARD) will be lost!)
	@bash -c 'read -p "Are you sure? [y/N] " -n 1 -r; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo ""; \
		echo "Flashing to $(SDCARD)..."; \
		dd if=$$(ls -t $(BUILD_DIR)/images/mimiki-sdcard.img) \
		        of=$(SDCARD) \
		        bs=4M \
		        status=progress \
		        conv=fsync; \
		echo ""; \
		echo "Flashing complete! Syncing..."; \
		sync; \
		echo "Done! You can now safely remove the SD card."; \
	else \
		echo ""; \
		echo "Aborted."; \
	fi'

clean:
	$(call MSG_INFO,Cleaning build directory...)
	@rm -rf $(BUILD_DIR)

clean-all: clean
	$(call MSG_INFO,Cleaning boot builds...)
	@$(MAKE) -C external/boot/u-boot mrproper || true
	@$(MAKE) -C external/boot/linux mrproper || true
	$(call MSG_INFO,Cleaning rocknix-sourced builds...)
	@$(MAKE) -C external/rocknix/generic-dsi clean || true
	@$(MAKE) -C external/rocknix/mali_kbase/product/kernel/drivers/gpu/arm/midgard KDIR=$(realpath ./external/boot/linux) clean || true
	@$(MAKE) -C external/rocknix/rocknix-joypad clean || true
	$(call MSG_INFO,Cleaning tool builds...)
	@$(MAKE) -C external/tools/busybox clean 2>/dev/null || true
	@rm -r external/tools/exfatprogs/build 2>/dev/null || true
	@$(MAKE) -C external/tools/gptfdisk clean || true
	@rm -r external/tools/SDL2/build 2>/dev/null || true
	@rm -r external/tools/SDL2_image/build 2>/dev/null || true
	@rm -r external/tools/alsa-utils/build 2>/dev/null || true
	$(call MSG_INFO,Cleaning Launcher build...)
	@$(MAKE) -C system/launcher clean || true
	$(call MSG_INFO,Cleaning Emulator builds...)
	$(call MSG_INFO,Cleaning mupen64plus builds...)
# Some of these need APIDIR because ???? to clean, even if it's incorrect
	@$(MAKE) -C external/emulators/mupen64plus/core/projects/unix clean || true
	@$(MAKE) -C external/emulators/mupen64plus/audio-sdl/projects/unix APIDIR=. clean || true
	@$(MAKE) -C external/emulators/mupen64plus/input-sdl/projects/unix APIDIR=. clean || true
	@rm -r external/emulators/mupen64plus/rdp-parallel/build 2>/dev/null || true
	@rm -r external/emulators/mupen64plus/rsp-parallel/build 2>/dev/null || true
	@$(MAKE) -C external/emulators/mupen64plus/ui-console/projects/unix APIDIR=. clean || true
	$(call MSG_SUCCESS,All clean!)
