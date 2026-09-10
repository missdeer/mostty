#!/bin/bash
# Run from the repository root in a macOS GUI session with Metal and permission
# to post pointer events (Accessibility). The tab-bar test restores the pointer.
set -euo pipefail
WORK="$PWD/tmp/macos-interaction-tests"
mkdir -p "$WORK"
zig build-obj src/input_capi.zig -fcompiler-rt -femit-bin="$WORK/input-core.o"
clang -fobjc-arc -c tests/macos/ClipboardBridge.m -o "$WORK/clipboard.o"
clang -fobjc-arc -c tests/macos/InteractionBridge.m -o "$WORK/interaction.o"
swiftc -D MOSTTY_APP_TESTS -module-cache-path "$PWD/tmp/swift-module-cache" \
    -import-objc-header tests/macos/InteractionBridge.h \
    src/macos/app/KeyInput.swift src/macos/app/TerminalView.swift src/macos/app/AppShell.swift \
    tests/macos/InteractionTests.swift "$WORK/clipboard.o" "$WORK/interaction.o" \
    "$WORK/input-core.o" \
    -framework AppKit -framework Metal -framework QuartzCore \
    -o "$WORK/interaction-tests"
"$WORK/interaction-tests"
