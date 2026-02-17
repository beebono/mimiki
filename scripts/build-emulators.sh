#!/bin/bash
# MIMIKI - Emulators Build Script
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build mupen64plus (big dude needs his own script over here...)
"$SCRIPTS_DIR/build-mupen64plus.sh"

# TODO: The other emulators
