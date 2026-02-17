# MIMIKI Launcher - Makefile
# Cross-compiles the launcher for ARM64

# Cross-compilation settings
CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
STRIP := $(CROSS_COMPILE)strip

# Directories
SRC_DIR := src
BUILD_DIR := build

# Compiler flags
CFLAGS := -Wall -Wextra -O2 -std=c11
CFLAGS += -I../../build/sdl2-install/usr/include
CFLAGS += -I../../build/sdl2-install/usr/include/SDL2

# Linker flags
LDFLAGS := -L../../build/sdl2-install/usr/lib
LIBS := -lSDL2 -lSDL2_image -lm -lpthread -ldl

# Target binary
TARGET := mimiki-launcher

# Source files
SRCS := $(wildcard $(SRC_DIR)/*.c)
OBJS := $(SRCS:$(SRC_DIR)/%.c=$(BUILD_DIR)/%.o)

# Phony targets
.PHONY: all clean

# Default target
all: $(BUILD_DIR)/$(TARGET)

# Create build directory
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Compile object files
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

# Link executable
$(BUILD_DIR)/$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) $^ $(LIBS) -o $@
	$(STRIP) --strip-unneeded $@
	@echo "Built: $@"
	@file $@

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
