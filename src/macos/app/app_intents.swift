import AppIntents

struct TerminalEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Terminal")
    static let defaultQuery = TerminalQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name) (\(id))") }
    init(_ pane: PaneItem) { id = pane.automationID; name = pane.title }
}

struct TerminalQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [TerminalEntity] {
        TerminalAutomation.terminals.filter { identifiers.contains($0.automationID) }.map(TerminalEntity.init)
    }
    @MainActor func suggestedEntities() async throws -> [TerminalEntity] {
        TerminalAutomation.terminals.map(TerminalEntity.init)
    }
}

struct NewTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Terminal Tab"
    static let description = IntentDescription("Open a Mostty tab, optionally in a directory or running a shell command.")
    static let openAppWhenRun = true
    @Parameter(title: "Working Directory", default: "") var directory: String
    @Parameter(title: "Command", default: "") var command: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<TerminalEntity> {
        .result(value: TerminalEntity(try TerminalAutomation.newTab(directory: directory, command: command)))
    }
}

struct FocusTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Focus Terminal"
    static let openAppWhenRun = true
    @Parameter(title: "Terminal") var terminal: TerminalEntity
    @MainActor func perform() async throws -> some IntentResult {
        try TerminalAutomation.focus(terminal.id)
        return .result()
    }
}

struct CloseTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Terminal"
    static let description = IntentDescription("Close a terminal using Mostty's configured confirmation policy.")
    static let openAppWhenRun = true
    @Parameter(title: "Terminal") var terminal: TerminalEntity
    @MainActor func perform() async throws -> some IntentResult {
        try TerminalAutomation.close(terminal.id)
        return .result()
    }
}

struct InputTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Input Text to Terminal"
    static let description = IntentDescription("Send literal text. Include a carriage return to submit a command.")
    static let openAppWhenRun = true
    @Parameter(title: "Terminal") var terminal: TerminalEntity
    @Parameter(title: "Text") var text: String
    @MainActor func perform() async throws -> some IntentResult {
        try TerminalAutomation.input(text, to: terminal.id)
        return .result()
    }
}

enum SplitDirection: String, AppEnum {
    case right, down
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Split Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.right: "Right", .down: "Down"]
}

struct SplitTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Split Terminal"
    static let openAppWhenRun = true
    @Parameter(title: "Terminal") var terminal: TerminalEntity
    @Parameter(title: "Direction", default: .right) var direction: SplitDirection
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<TerminalEntity> {
        .result(value: TerminalEntity(try TerminalAutomation.split(terminal.id, down: direction == .down)))
    }
}

struct GetTerminalDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Terminal Details"
    static let openAppWhenRun = true
    @Parameter(title: "Terminal") var terminal: TerminalEntity
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let (_, pane) = try TerminalAutomation.resolve(terminal.id)
        return .result(value: "\(pane.title)\n\(pane.view.workingDirectory ?? "")\nAt prompt: \(pane.view.atPrompt)")
    }
}

struct MosttyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewTabIntent(), phrases: ["Open a terminal in \(.applicationName)"],
                    shortTitle: "New Terminal", systemImageName: "terminal")
    }
}
