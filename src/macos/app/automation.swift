import AppKit

enum TerminalDirectory {
    static func localPath(_ report: String, host: String = ProcessInfo.processInfo.hostName) -> String? {
        let raw: Bool
        let rest: Substring
        if report.hasPrefix("kitty-shell-cwd://") {
            raw = true
            rest = report.dropFirst("kitty-shell-cwd://".count)
        } else if report.hasPrefix("file://") {
            raw = false
            rest = report.dropFirst("file://".count)
        } else { return nil }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let authority = String(rest[..<slash]).lowercased()
        let local = host.lowercased()
        guard authority.isEmpty || authority == "localhost" || authority == local ||
                authority == local.split(separator: ".").first.map(String.init) else { return nil }
        let encoded = String(rest[slash...])
        guard let path = raw ? encoded : encoded.removingPercentEncoding,
              !path.utf8.contains(0) else { return nil }
        return path
    }
}

enum TerminalAutomation {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static var terminals: [PaneItem] { AppModel.shared.tabs.flatMap(\.panes) }

    static func resolve(_ id: String?) throws -> (TabItem, PaneItem) {
        let model = AppModel.shared
        if id == nil, let tab = model.selectedTab, let pane = tab.activePane { return (tab, pane) }
        for tab in model.tabs {
            if let pane = tab.panes.first(where: { $0.automationID == id }) { return (tab, pane) }
        }
        throw Failure("The terminal no longer exists.")
    }

    static func focus(_ id: String?) throws {
        let (tab, pane) = try resolve(id)
        let model = AppModel.shared
        model.selectedID = tab.id
        guard mostty_layout_focus(tab.layout, pane.id) else { throw Failure("Unable to focus terminal.") }
        tab.host.arrange()
        model.focusActivePane()
        tab.host.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func newTab(directory: String = "", command: String = "") throws -> PaneItem {
        if !directory.isEmpty {
            var isDirectory: ObjCBool = false
            guard directory.hasPrefix("/"), !directory.utf8.contains(0),
                  FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure("The working directory must be an existing absolute directory.")
            }
        }
        guard !command.utf8.contains(0) else { throw Failure("The command contains a NUL character.") }
        let model = AppModel.shared
        let previous = model.selectedID
        let launcher = directory.isEmpty && command.isEmpty ? nil :
            TerminalLauncher(label: "", command: command, directory: directory)
        model.newTab(launcher: launcher)
        guard model.selectedID != previous, let tab = model.selectedTab, let pane = tab.activePane else {
            throw Failure("Unable to start terminal.")
        }
        guard pane.view.hasStartedSession else {
            model.close(tab.id, confirm: false)
            if let previous = previous, model.tabs.contains(where: { $0.id == previous }) { model.selectedID = previous }
            throw Failure("Unable to start terminal.")
        }
        return pane
    }

    static func split(_ id: String?, down: Bool) throws -> PaneItem {
        try focus(id)
        let model = AppModel.shared
        let previous = model.selectedTab?.activePane?.id
        model.splitSelected(down ? 1 : 0)
        guard let pane = model.selectedTab?.activePane, pane.id != previous else {
            throw Failure("The terminal is too small to split, or the new session could not start.")
        }
        return pane
    }

    static func close(_ id: String?) throws {
        let (tab, pane) = try resolve(id)
        AppModel.shared.closePane(pane.id, in: tab)
        if terminals.contains(where: { $0.id == pane.id }) { throw Failure("Closing the terminal was cancelled.") }
    }

    static func input(_ text: String, to id: String?) throws {
        let (_, pane) = try resolve(id)
        guard pane.view.inputText(text) else { throw Failure("Unable to enqueue terminal input.") }
    }
}

@objc(MosttyScriptTerminal)
final class MosttyScriptTerminal: NSObject {
    private let terminalID: String
    init(_ pane: PaneItem) { terminalID = pane.automationID }
    @objc var id: String { terminalID }
    private var pane: PaneItem? { try? TerminalAutomation.resolve(id).1 }
    @objc var name: String { pane?.title ?? "" }
    @objc var workingDirectory: String { pane?.view.workingDirectory ?? "" }
    @objc var atPrompt: Bool { pane?.view.atPrompt ?? false }
    @objc var selected: Bool { AppModel.shared.selectedTab?.activePane?.automationID == terminalID }
    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let description = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil,
                                   key: "terminals", uniqueID: id)
    }
}

@objc(MosttyScriptCommand)
final class MosttyScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        precondition(Thread.isMainThread)
        let arguments = evaluatedArguments ?? [:]
        let id = arguments["terminalID"] as? String
        do {
            switch commandDescription.commandName {
            case "new tab":
                return MosttyScriptTerminal(try TerminalAutomation.newTab(
                    directory: arguments["directory"] as? String ?? "",
                    command: arguments["command"] as? String ?? ""))
            case "focus terminal": try TerminalAutomation.focus(directParameter as? String)
            case "close terminal": try TerminalAutomation.close(directParameter as? String)
            case "split terminal":
                let direction = arguments["direction"] as? String ?? "right"
                guard direction == "right" || direction == "down" else { throw TerminalAutomation.Failure("Direction must be right or down.") }
                return MosttyScriptTerminal(try TerminalAutomation.split(directParameter as? String, down: direction == "down"))
            case "input text":
                guard let text = directParameter as? String else { throw TerminalAutomation.Failure("Text is required.") }
                try TerminalAutomation.input(text, to: id)
            default: throw TerminalAutomation.Failure("Unknown terminal command.")
            }
            return nil
        } catch {
            scriptErrorNumber = -1708
            scriptErrorString = error.localizedDescription
            return nil
        }
    }
}
