#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT_DIR"

while IFS= read -r line; do
    if [[ "$line" =~ \.minimum_zig_version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        ZIG_VERSION="${BASH_REMATCH[1]}"
        break
    fi
done < build.zig.zon
if [[ -z "${ZIG:-}" && "$(zig version 2>/dev/null || true)" != "$ZIG_VERSION" ]]; then
    for candidate in "$HOME"/zig-*-"$ZIG_VERSION"/zig; do
        if [[ -x "$candidate" && "$("$candidate" version 2>/dev/null || true)" == "$ZIG_VERSION" ]]; then
            ZIG="$candidate"
            break
        fi
    done
fi
ZIG="${ZIG:-zig}"
if [[ "$("$ZIG" version 2>/dev/null || true)" != "$ZIG_VERSION" ]]; then
    echo "Zig $ZIG_VERSION is required; set ZIG to its executable path." >&2
    exit 1
fi

export ZIG_GLOBAL_CACHE_DIR="$ROOT_DIR/.zig-cache"
"$ZIG" build -Doptimize=ReleaseFast

if [[ "$(uname -s)" == "Darwin" ]]; then
    SIGN_ID="${SIGN_ID:-Developer ID Application: Fan Yang (Y73SBCN2CG)}"
    APP="$ROOT_DIR/zig-out/Mostty.app"
    # Sign the complete bundle with a stable identity for macOS privacy grants.
    codesign --force --timestamp=none --options runtime --sign "$SIGN_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi
