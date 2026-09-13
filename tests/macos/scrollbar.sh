#!/bin/bash
# Run from the repository root in a macOS GUI login session with Metal available.
set -euo pipefail
WORK="$PWD/tmp/macos-scrollbar-tests"
mkdir -p "$WORK"
zig build-obj src/input_capi.zig -fcompiler-rt -femit-bin="$WORK/input-core.o"
zig build-obj src/layout_capi.zig -fno-compiler-rt -femit-bin="$WORK/layout-core.o"
swiftc -D MOSTTY_APP_TESTS -module-cache-path "$PWD/tmp/swift-module-cache" \
    -import-objc-header src/macos/app/Bridge.h \
    src/macos/app/key_input.swift src/macos/app/terminal_view.swift src/macos/app/pane_container.swift src/macos/app/app_shell.swift \
    tests/macos/ScrollbarTests.swift tests/macos/ClipboardBridge.swift tests/macos/InteractionBridge.swift \
    "$WORK/input-core.o" \
    "$WORK/layout-core.o" \
    -framework AppKit -framework Metal -framework QuartzCore \
    -o "$WORK/scrollbar-tests"
"$WORK/scrollbar-tests"
