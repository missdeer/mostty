// Verify that a built macOS app ships every bundled theme unchanged.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
guard CommandLine.arguments.count == 2 else { fail("usage: swift tests/macos/bundle-themes.swift Mostty.app") }
let source = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("themes")
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = app.appendingPathComponent("Contents/Resources/themes")
let manager = FileManager.default
var isDirectory: ObjCBool = false
guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("Missing bundled themes directory: \(destination.path)")
}
guard let entries = manager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey],
                                      errorHandler: { url, error in fail("\(url.path): \(error)") }) else {
    fail("No source themes found in \(source.path)")
}
let themes = try entries.compactMap { $0 as? URL }.filter {
    try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
}.sorted { $0.path < $1.path }
guard !themes.isEmpty else { fail("No source themes found in \(source.path)") }
for theme in themes {
    let relative = String(theme.path.dropFirst(source.path.count + 1))
    let installed = destination.appendingPathComponent(relative)
    guard (try? installed.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        fail("Missing bundled theme: \(relative)")
    }
    guard try Data(contentsOf: installed) == Data(contentsOf: theme) else {
        fail("Bundled theme content differs: \(relative)")
    }
}
print("Verified \(themes.count) bundled themes in \(CommandLine.arguments[1])")
