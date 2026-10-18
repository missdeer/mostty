import Foundation

let bundle = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "zig-out/Mostty.app")
let resources = bundle.appendingPathComponent("Contents/Resources")
let required = [
    "Mostty.sdef", "Metadata.appintents/extract.actionsdata",
    "mostty/shell-integration/zsh/.zshenv", "mostty/shell-integration/zsh/mostty-integration",
    "mostty/shell-integration/bash/mostty.bash", "mostty/shell-integration/bash/bash-preexec.sh",
    "mostty/shell-integration/fish/vendor_conf.d/mostty-shell-integration.fish",
    "mostty/shell-integration/nushell/vendor/autoload/mostty.nu",
    "mostty/shell-integration/elvish/lib/mostty-integration.elv",
    "mostty/shell-integration/COPYING.GPLv3", "mostty/shell-integration/LICENSE.Ghostty",
    "mostty/shell-integration/LICENSE.bash-preexec",
    "vim/vimfiles/ftdetect/mostty.vim", "vim/vimfiles/syntax/mostty.vim", "vim/vimfiles/ftplugin/mostty.vim",
    "nvim/site/ftdetect/mostty.vim", "nvim/site/syntax/mostty.vim", "nvim/site/ftplugin/mostty.vim",
    "vim/vimfiles/compiler/mostty.vim", "nvim/site/compiler/mostty.vim",
    "bat/syntaxes/mostty.sublime-syntax", "bash-completion/completions/Mostty",
    "zsh/site-functions/_Mostty", "fish/vendor_completions.d/Mostty.fish"
]
for path in required {
    let data = try Data(contentsOf: resources.appendingPathComponent(path))
    precondition(!data.isEmpty, "Empty integration resource: \(path)")
}
let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent("Metadata.appintents/extract.actionsdata"))) as! [String: Any]
let actions = metadata["actions"] as! [String: Any]
let expected: Set<String> = ["NewTabIntent", "FocusTerminalIntent", "CloseTerminalIntent", "InputTextIntent", "SplitTerminalIntent", "GetTerminalDetailsIntent"]
precondition(Set(actions.keys) == expected, "Every shipped shortcut must have generated runtime metadata")
let syntax = try String(contentsOf: resources.appendingPathComponent("bat/syntaxes/mostty.sublime-syntax"), encoding: .utf8)
precondition(syntax.contains("shell-integration") && syntax.contains("launcher") && !syntax.contains("macos-icon"),
             "Editor support must describe Mostty's configuration, including its own options")
for editor in ["vim/vimfiles", "nvim/site"] {
    let detect = try String(contentsOf: resources.appendingPathComponent(editor + "/ftdetect/mostty.vim"), encoding: .utf8)
    precondition(detect.contains("*/com.dfordsoft.mostty.terminal/Config"),
                 "Filetype detection must cover the application's capitalized macOS config filename")
}
let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
precondition(plist["NSAppleScriptEnabled"] as? Bool == true && plist["OSAScriptingDefinition"] as? String == "Mostty.sdef",
             "The scripting dictionary must be registered, not merely copied into Resources")
print("PASS: \(required.count) integration resources, six App Intents, and AppleScript registration")

let work = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/resource-cli-tests")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let invalid = work.appendingPathComponent("invalid config '\(UUID().uuidString)'.mostty")
try "# a comment\nfont-size = invalid\n# background = ignored\nbackground = not-a-color\nfont-feature = bad\ntheme = \(invalid.path).missing-theme\n".write(to: invalid, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: invalid) }
let commented = work.appendingPathComponent("commented-\(UUID().uuidString).mostty")
try "# a comment without an equals sign\n # font-size = invalid\nfont-size = 14\nbackground = #112233\n".write(to: commented, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(at: commented) }
func validate(_ path: String) throws -> (Int32, String) {
    let process = Process()
    let errors = Pipe()
    process.executableURL = bundle.appendingPathComponent("Contents/MacOS/Mostty")
    process.arguments = ["+validate-config", "--config-file", path]
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}
let validResult = try validate("tests/macos/interaction-theme")
precondition(validResult.0 == 0, "Valid Mostty configuration must pass headless validation")
let commentedResult = try validate(commented.path)
precondition(commentedResult.0 == 0, "The editor's comment syntax must be accepted by configuration validation")
let invalidResult = try validate(invalid.path)
precondition(invalidResult.0 == 1 && [2, 4, 5, 6].allSatisfy { invalidResult.1.contains(invalid.path + ":\($0):") },
             "Typed values, font features and themes must report their actual file/line, counting comments too")
let missingResult = try validate(invalid.path + ".missing")
precondition(missingResult.0 == 2, "Missing configuration must fail instead of validating defaults")
print("PASS: configuration validation exit codes and editor file/line diagnostics")
