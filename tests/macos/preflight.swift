import AppKit
import Metal
import CoreGraphics

// Read-only probes. CI never changes TCC permissions or system policy.
guard MTLCreateSystemDefaultDevice() != nil, !NSScreen.screens.isEmpty else {
    print("blocked: a logged-in macOS desktop with Metal is required")
    exit(77)
}
if CommandLine.arguments.contains("pointer"), !CGPreflightPostEventAccess() {
    print("blocked: pointer injection permission is required for interactions")
    exit(77)
}
