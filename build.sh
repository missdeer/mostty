#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

export ZIG_GLOBAL_CACHE_DIR="$ROOT_DIR/.zig-cache"
zig build -Doptimize=ReleaseFast

if [[ "$(uname -s)" == "Darwin" ]]; then
    SIGN_ID="${SIGN_ID:-Developer ID Application: Fan Yang (Y73SBCN2CG)}"
    APP="$ROOT_DIR/zig-out/Mostty.app"
    # Sign the complete bundle with a stable identity for macOS privacy grants.
    codesign --force --timestamp=none --options runtime --sign "$SIGN_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi
