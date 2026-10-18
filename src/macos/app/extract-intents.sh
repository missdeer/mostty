#!/bin/bash
set -euo pipefail
SRCDIR="$1"
TARGET="$2"
CONSTANTS="$3"
OUT="$4"
mkdir -p "$OUT"
SOURCES="$OUT/sources.txt"
VALUES="$OUT/const-values.txt"
printf '%s\n' "$SRCDIR/app_intents.swift" > "$SOURCES"
# Whole-module compilation emits a declared supplementary constants file.
# Feed it to Apple's metadata processor instead of copying foreign metadata.
printf '%s\n' "$CONSTANTS" > "$VALUES"
xcrun appintentsmetadataprocessor \
    --output "$OUT" \
    --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
    --module-name Mostty \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | tail -n 1 | cut -d ' ' -f 3)" \
    --platform-family macOS --deployment-target 13.0 --target-triple "$TARGET" \
    --source-file-list "$SOURCES" --swift-const-vals-list "$VALUES"
test -s "$OUT/Metadata.appintents/extract.actionsdata"
rm "$SOURCES" "$VALUES"
