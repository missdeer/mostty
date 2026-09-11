#!/bin/bash
# Compile the SwiftUI app and link it against the Zig terminal core.
#
# Invoked by build.zig. Zig's archiver packs archive members without the 8-byte
# alignment Apple's linker requires, so instead of linking the .a files directly
# we extract their object files (loose objects have no such constraint) and hand
# them to swiftc. Arguments:
#   $1        output executable path
#   $2        directory containing the Swift sources and Bridge.h
#   $3        swiftc target triple (must match the Zig core's arch)
#   $4..$N    static archives to link (Zig core + transitive C++ archives)
set -euo pipefail

OUT="$1"; shift
SRCDIR="$1"; shift
TARGET="$1"; shift
TEST_ARGS=()
if [[ "${1:-}" == "--test" ]]; then
    TEST_ARGS=(-D MOSTTY_APP_TESTS "$2")
    shift 2
fi

# Keep the object-extraction scratch dir inside the build tree (next to the
# output), not the system temp: the build sandbox restricts access to /var tmp.
WORK="$(dirname "$OUT")/mostty-link-objs.$$"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

index=0
for archive in "$@"; do
    # Resolve relative archive paths (passed relative to the build root) before
    # descending into the extraction directory.
    abs="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
    dir="$WORK/a$index"
    mkdir -p "$dir"
    ( cd "$dir" && ar x "$abs" )
    index=$((index + 1))
done

# Zig's archiver stores member mode 0, so extracted objects come out unreadable;
# restore read/write before handing them to the linker.
chmod -R u+rw "$WORK"

swiftc -O -o "$OUT" \
    ${TEST_ARGS[@]+"${TEST_ARGS[@]}"} \
    -target "$TARGET" \
    -import-objc-header "$SRCDIR/Bridge.h" \
    "$SRCDIR/KeyInput.swift" \
    "$SRCDIR/TerminalView.swift" \
    "$SRCDIR/PaneContainer.swift" \
    "$SRCDIR/AppShell.swift" \
    "$WORK"/a*/*.o \
    -lc++ \
    -framework Cocoa \
    -framework Metal \
    -framework QuartzCore \
    -framework CoreText \
    -framework CoreGraphics \
    -framework ImageIO \
    -framework Foundation
