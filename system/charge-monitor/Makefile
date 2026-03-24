# MIMIKI Charge Monitor - Makefile

CROSS_COMPILE ?= aarch64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
STRIP := $(CROSS_COMPILE)strip

CFLAGS := -Wall -Wextra -Wno-unused-result -Os -std=c11 -static
TARGET := charge-monitor

.PHONY: all clean

all: $(TARGET)

$(TARGET): charge-monitor.c
	$(CC) $(CFLAGS) $< -o $@
	$(STRIP) --strip-all $@

clean:
	rm -f $(TARGET)
