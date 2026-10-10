#!/bin/bash
set -uo pipefail
cd "$(dirname "$0")/../.."
mkdir -p tmp/ci-macos
summary="$PWD/tmp/ci-macos/results.tsv"
printf 'suite\tstatus\tdetail\n' > "$summary"
failed=0
run_suite() {
    local name="$1"
    shift
    "$@" > "tmp/ci-macos/$name.log" 2>&1
    local result=$?
    if [ "$result" -eq 0 ]; then
        local status=pass
        case "$name" in *-compile) status=compile-only ;; esac
        printf '%s\t%s\texit 0; see log for individual skipped tests\n' "$name" "$status" >> "$summary"
    else
        printf '%s\tfail\texit %s\n' "$name" "$result" >> "$summary"
        failed=1
    fi
    if [ "$result" -eq 0 ]; then
        tail -n 12 "tmp/ci-macos/$name.log"
    else
        cat "tmp/ci-macos/$name.log"
    fi
}
run_suite unit zig build test --global-cache-dir .zig-cache --summary all
run_suite bundle-themes swift -module-cache-path "$PWD/tmp/swift-module-cache" tests/macos/bundle-themes.swift zig-out/Mostty.app
swiftc -module-cache-path "$PWD/tmp/swift-module-cache" tests/macos/preflight.swift -o tmp/ci-macos/preflight
preflight_build=$?
if [ "$preflight_build" -ne 0 ]; then
    printf 'preflight\tfail\tcompile error\n' >> "$summary"
    exit 1
fi
if tmp/ci-macos/preflight; then
    run_suite panes zig build test-macos-panes --global-cache-dir .zig-cache --summary all
    run_suite pane-config zig build test-macos-pane-config --global-cache-dir .zig-cache --summary all
    run_suite clipboard bash tests/macos/clipboard.sh
    run_suite scrollbar bash tests/macos/scrollbar.sh
    if tmp/ci-macos/preflight pointer; then
        run_suite interactions bash tests/macos/interactions.sh
    else
        printf 'interactions\tblocked\tpointer permission unavailable\n' >> "$summary"
        run_suite interactions-compile bash tests/macos/interactions.sh --compile-only
    fi
else
    for suite in panes pane-config clipboard scrollbar interactions; do
        printf '%s\tblocked\tGUI/Metal unavailable\n' "$suite" >> "$summary"
    done
    run_suite panes-compile zig build check-macos-panes --global-cache-dir .zig-cache --summary all
    run_suite clipboard-compile bash tests/macos/clipboard.sh --compile-only
    run_suite scrollbar-compile bash tests/macos/scrollbar.sh --compile-only
    run_suite interactions-compile bash tests/macos/interactions.sh --compile-only
fi
printf 'Intel/AMD-GPU\tblocked\trequires a physical Intel/AMD Mac run\n' >> "$summary"
while IFS= read -r line; do printf '%s\n' "$line"; done < "$summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '\nMac test inventory (blocked is not passed):\n\n```text\n' >> "$GITHUB_STEP_SUMMARY"
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$summary" >> "$GITHUB_STEP_SUMMARY"
    printf '```\n' >> "$GITHUB_STEP_SUMMARY"
fi
exit "$failed"
