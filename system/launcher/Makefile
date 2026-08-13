# MIROKI Launcher - Makefile

# Cross-compilation settings
CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
STRIP := $(CROSS_COMPILE)strip

# Directories
SRC_DIR := src
BUILD_DIR := build

# Compiler flags
CFLAGS := -Wall -Wextra -Wno-unused-result -O3 -flto=auto -std=c11

# Linker flags
LIBS := -lncurses -lpthread

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
	$(CC) $^ $(LIBS) -o $@
	$(STRIP) --strip-unneeded $@
	@echo "Built: $@"
	@file $@

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR)
