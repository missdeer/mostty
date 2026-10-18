#!/bin/bash
set -euo pipefail
WORK="$PWD/tmp/macos-automation-tests"
APP="$WORK/MosttyAutomationTests.app"
mkdir -p "$WORK"
if [[ -d "$APP" ]]; then rm -rf "$APP"; fi
cp -R "$2" "$APP"
cp "$1" "$APP/Contents/MacOS/Mostty"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.dfordsoft.mostty.automation-tests' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName MosttyAutomationTests' "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/Mostty" "$APP"
