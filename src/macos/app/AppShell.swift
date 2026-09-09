import SwiftUI
import AppKit

final class TabItem: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = "Terminal"
    let view = MosttyTerminalView(frame: .zero)
}

/// Watches the config file and re-applies it without a restart.
///
/// Both the file and its directory are watched, because editors disagree on how
/// they save. An in-place write only touches the file, while a write-temp-then-
/// rename never touches the original inode at all — watching one alone misses
/// half the editors in use.
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init?(onChange: @escaping () -> Void) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = mostty_config_path(&buf, buf.count)
        guard n > 0 else { return nil }
        path = String(decoding: buf[0..<n], as: UTF8.self)
        self.onChange = onChange

        let directory = (path as NSString).deletingLastPathComponent
        // Opening requires the directory to exist; a user who has never saved a
        // config still gets live reload once they do.
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard let source = Self.makeSource(directory, mask: [.write, .rename, .delete]) else { return nil }
        directorySource = source
        source.setEventHandler { [weak self] in self?.schedule() }
        source.resume()
        watchFile()
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private static func makeSource(
        _ path: String,
        mask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: mask, queue: .main)
        source.setCancelHandler { close(descriptor) }
        return source
    }

    // A file source is bound to an inode, so it must be re-established after
    // every event: a rename-based save leaves it watching the replaced file, and
    // the config may not have existed when the watcher started.
    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil
        // Truncating to an empty file can emit only NOTE_ATTRIB on macOS.
        guard let source = Self.makeSource(path, mask: [.write, .extend, .attrib, .rename, .delete]) else { return }
        fileSource = source
        source.setEventHandler { [weak self] in self?.schedule() }
        source.resume()
    }

    // One save emits several events across both sources, and the editor may not
    // have finished writing when the first arrives; coalesce and let it settle.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.watchFile()
            self.onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tabs: [TabItem] = []
    @Published var selectedID: UUID?
    @Published var launchers: [TerminalLauncher] = []
    @Published var themes: [String] = []
    @Published var activeTheme = ""
    private var confirmingClose = false
    private let windowDelegate = TerminalWindowDelegate()

    var selectedTab: TabItem? { tabs.first { $0.id == selectedID } }

    /// The live terminal container, so a config reload can refresh the backdrop.
    weak var container: ContainerView?
    private var configWatcher: ConfigWatcher?

    init() {
        refreshMenus()
        newTab()
        configWatcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
    }

    /// Re-read the config and push it to every live tab plus the window chrome.
    /// `maximize` / `fullscreen` are deliberately not re-applied: they describe
    /// the initial window state, so honoring them here would fight a window the
    /// user has since resized.
    func reloadConfig() {
        guard mostty_config_reload() else { return }
        refreshMenus()
        applyConfig()
    }

    private func applyConfig() {
        // Every tab adopts the new font first, then the on-screen tab derives the
        // grid once and broadcasts it. Doing the resize inside the loop would let
        // the active tab publish a grid before the others had the metrics for it,
        // leaving background sessions on the old size until they are next shown.
        for tab in tabs { tab.view.applyConfig() }
        selectedTab?.view.resyncSurface()
        container?.applyBackdrop()
        container?.applyWindowAppearance()
    }

    /// Applies `maximize` / `fullscreen` once the window exists. SwiftUI creates
    /// it after `applicationDidFinishLaunching`, so this runs a turn later. Only
    /// one-shot actions belong here; window *state* such as opacity is owned by
    /// ContainerView, which re-asserts it after SwiftUI builds the scene.
    func applyInitialWindowState() {
        guard let window = terminalWindow() else { return }
        installWindowDelegate(window)
        if mostty_config_maximize(), !window.isZoomed { window.zoom(nil) }
        if mostty_config_fullscreen(), !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // The terminal's own window, rather than whichever window AppKit lists
    // first — a font panel or similar auxiliary window must not be restyled.
    private func terminalWindow() -> NSWindow? {
        container?.window ?? NSApp.windows.first { $0.contentView != nil }
    }

    private func readText(_ read: (UnsafeMutablePointer<UInt8>, Int) -> Int) -> String {
        var probe: UInt8 = 0
        let count = read(&probe, 0)
        guard count > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: count)
        let written = read(&buffer, buffer.count)
        return String(decoding: buffer.prefix(written), as: UTF8.self)
    }

    func refreshMenus() {
        launchers = (0..<mostty_config_launcher_count()).map { index in
            TerminalLauncher(
                label: readText { mostty_config_launcher_text(index, 0, $0, $1) },
                command: readText { mostty_config_launcher_text(index, 1, $0, $1) },
                directory: readText { mostty_config_launcher_text(index, 2, $0, $1) })
        }
        themes = (0..<mostty_config_refresh_themes()).map { index in
            readText { mostty_config_theme_name(index, $0, $1) }
        }
        activeTheme = readText { mostty_config_active_theme($0, $1) }
    }

    func selectTheme(_ name: String) {
        guard mostty_config_select_theme(name) else {
            showError("Unable to Load Theme", detail: name)
            return
        }
        activeTheme = name
        applyConfig()
    }

    func openConfig() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = mostty_config_path(&buffer, buffer.count)
        guard count > 0 else {
            showError("Unable to Open Configuration", detail: "The configuration path is unavailable.")
            return
        }
        let url = URL(fileURLWithPath: String(decoding: buffer.prefix(count), as: UTF8.self))
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .withoutOverwriting)
            }
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error {
                    DispatchQueue.main.async { self.showError("Unable to Open Configuration", detail: error.localizedDescription) }
                }
            }
        } catch {
            showError("Unable to Open Configuration", detail: error.localizedDescription)
        }
    }

    private func showError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    func toggleFullscreen() { terminalWindow()?.toggleFullScreen(nil) }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func cycleTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedID } ?? 0
        selectTab(at: (current + delta % tabs.count + tabs.count) % tabs.count)
    }

    func installWindowDelegate(_ window: NSWindow) {
        guard window.delegate !== windowDelegate else { return }
        windowDelegate.original = window.delegate
        windowDelegate.model = self
        window.delegate = windowDelegate
    }

    func newTab(launcher: TerminalLauncher? = nil) {
        let item = TabItem()
        item.view.launcher = launcher
        item.view.onTitleChange = { [weak item] title in
            item?.title = title.isEmpty ? "Terminal" : title
        }
        item.view.onExit = { [weak self, weak item] in
            guard let self = self, let item = item else { return }
            self.close(item.id, confirm: false)
        }
        item.view.onSurfaceResize = { [weak self, weak item] pw, ph, scale in
            guard let self = self, let item = item else { return }
            for other in self.tabs where other.id != item.id {
                other.view.applyExternalSurface(pw, ph, scale)
            }
        }
        tabs.append(item)
        selectedID = item.id
    }

    func closeSelected() {
        if let id = selectedID { close(id) }
    }

    func confirmClose(_ candidates: [TabItem]) -> Bool {
        guard !confirmingClose else { return false }
        guard mostty_config_confirm_close(), candidates.contains(where: { $0.view.hasActiveSession }) else { return true }
        confirmingClose = true
        defer {
            confirmingClose = false
            if tabs.isEmpty { DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
        let alert = NSAlert()
        alert.messageText = candidates.count == 1 ? "Close this terminal session?" : "Close all terminal sessions?"
        alert.informativeText = "Running processes will be terminated."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func close(_ id: UUID, confirm: Bool = true) {
        guard let candidate = tabs.first(where: { $0.id == id }) else { return }
        if confirm, !confirmClose([candidate]) { return }
        // The alert runs a nested event loop; a child can exit while it is open.
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let item = tabs.remove(at: idx)
        item.view.shutdown()
        if selectedID == id {
            selectedID = tabs.indices.contains(idx) ? tabs[idx].id : tabs.last?.id
        }
        if tabs.isEmpty { NSApplication.shared.terminate(nil) }
    }

    func shutdownAll() {
        for t in tabs { t.view.shutdown() }
        tabs.removeAll()
    }
}

/// Preserve SwiftUI's window delegate callbacks while intercepting close requests.
final class TerminalWindowDelegate: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var model: AppModel?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = model, model.confirmClose(model.tabs) else { return false }
        guard original?.windowShouldClose?(sender) ?? true else { return false }
        model.shutdownAll()
        return true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? { original }
}

/// Hosts the selected tab's persistent terminal view, swapping it on selection
/// change and handing it first-responder status.
struct TerminalHost: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView(frame: .zero)
        model.container = view
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.show(model.selectedTab?.view)
    }
}

final class ContainerView: NSView {
    private weak var current: NSView?
    private var backdrop: NSVisualEffectView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyBackdrop()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowAppearance()
        if let window = window {
            DispatchQueue.main.async { AppModel.shared.installWindowDelegate(window) }
        }
    }

    /// `background-opacity < 1` only shows through if the window itself stops
    /// painting an opaque background behind the Metal layer.
    ///
    /// This runs from `viewDidMoveToWindow` rather than at launch because
    /// SwiftUI assigns the scene's own background while building the window,
    /// which silently overwrites an assignment made any earlier.
    func applyWindowAppearance() {
        guard let window = window else { return }
        let translucent = mostty_config_background_opacity() < 1
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : .windowBackgroundColor
    }

    /// `background-blur` puts a vibrancy backdrop behind the terminal so
    /// translucent cells composite against the desktop instead of black. It is
    /// meaningless at full opacity, where nothing shows through.
    func applyBackdrop() {
        let wanted = mostty_config_background_blur() && mostty_config_background_opacity() < 1
        if wanted, backdrop == nil {
            let view = NSVisualEffectView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.blendingMode = .behindWindow
            // `.hudWindow` is the one material that stays genuinely see-through
            // in dark mode; the window-background materials render as a nearly
            // opaque panel and would hide the desktop instead of blurring it.
            view.material = .hudWindow
            view.state = .active
            addSubview(view, positioned: .below, relativeTo: nil)
            backdrop = view
        } else if !wanted, let view = backdrop {
            view.removeFromSuperview()
            backdrop = nil
        }
    }

    func show(_ view: NSView?) {
        guard current !== view else { return }
        current?.removeFromSuperview()
        current = view
        if let v = view {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(v)
            }
        }
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
        current?.frame = bounds
    }
}

enum SSHLaunchers {
    static func load(from url: URL) -> [TerminalLauncher] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 1024 * 1024 + 1), data.count <= 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [TerminalLauncher] {
        let bytes = Array(text.utf8)
        let count = mostty_ssh_hosts(bytes, bytes.count, nil, 0)
        guard count > 0 else { return [] }
        var hosts = [MosttySSHHost](repeating: MosttySSHHost(), count: count)
        let actual = mostty_ssh_hosts(bytes, bytes.count, &hosts, hosts.count)
        guard actual == count else { return [] }
        return hosts.map { entry in
            let host = String(decoding: bytes[entry.offset..<(entry.offset + entry.len)], as: UTF8.self)
            // Shell quoting stays native; parsing only identifies aliases.
            let quoted = "'" + host.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return TerminalLauncher(label: "[SSH: \(host)]", command: "ssh -- \(quoted)", directory: "")
        }
    }
}

final class LauncherMenuButton: NSButton {
    var configuredLaunchers: () -> [TerminalLauncher] = { [] }
    var openTab: (TerminalLauncher?) -> Void = { _ in }
    var sshConfigURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
        .appendingPathComponent(".ssh/config")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab")
        imagePosition = .imageOnly
        isBordered = false
        toolTip = "New Tab"
        target = self
        action = #selector(newTab(_:))
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    @objc private func newTab(_ sender: Any?) { openTab(nil) }

    @objc private func selectLauncher(_ sender: NSMenuItem) {
        guard let launcher = sender.representedObject as? TerminalLauncher else { return }
        openTab(launcher)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let configured = configuredLaunchers()
        let ssh = SSHLaunchers.load(from: sshConfigURL)
        guard !configured.isEmpty || !ssh.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, launcher) in (configured + ssh).enumerated() {
            if index == configured.count && !configured.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: launcher.label, action: #selector(selectLauncher(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = launcher
            menu.addItem(item)
        }
        return menu
    }
}

struct LauncherButton: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> LauncherMenuButton {
        LauncherMenuButton(frame: .zero)
    }

    func updateNSView(_ button: LauncherMenuButton, context: Context) {
        button.configuredLaunchers = { [weak model] in model?.launchers ?? [] }
        button.openTab = { [weak model] launcher in model?.newTab(launcher: launcher) }
    }
}

struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                TabChip(tab: tab, model: model)
            }
            LauncherButton(model: model)
                .frame(width: 22, height: 22)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabChip: View {
    @ObservedObject var tab: TabItem
    @ObservedObject var model: AppModel

    private var isSelected: Bool { model.selectedID == tab.id }

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .font(.system(size: 12))
            Button(action: { model.close(tab.id) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15))
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = tab.id }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabBar(model: model)
            TerminalHost(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.confirmClose(AppModel.shared.tabs) ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdownAll() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI has not built the Window scene yet at this point.
        DispatchQueue.main.async { AppModel.shared.applyInitialWindowState() }
    }
}

#if !MOSTTY_APP_TESTS
@main
#endif
struct MosttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Mostty", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 480, minHeight: 300)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Tab") { model.closeSelected() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Open Configuration File") { model.openConfig() }
                    .keyboardShortcut(",", modifiers: .command)
                Menu("Theme") {
                    ForEach(Array(Set(model.themes.map { themeBucket($0) })).sorted(), id: \.self) { bucket in
                        Menu(bucket) {
                            ForEach(model.themes.filter { themeBucket($0) == bucket }, id: \.self) { name in
                                Button { model.selectTheme(name) } label: {
                                    if name == model.activeTheme { Label(name, systemImage: "checkmark") }
                                    else { Text(name) }
                                }
                            }
                        }
                    }
                }
            }
            CommandMenu("Tabs") {
                Button("Previous Tab") { model.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Next Tab") { model.cycleTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Select Tab \(number)") { model.selectTab(at: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                        .disabled(model.tabs.count < number)
                }
            }
            CommandGroup(after: .windowSize) {
                Button("Toggle Full Screen") { model.toggleFullscreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") {
                    NSApp.sendAction(#selector(MosttyTerminalView.copy(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Paste") {
                    NSApp.sendAction(#selector(MosttyTerminalView.paste(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: .command)
            }
        }
    }

    private func themeBucket(_ name: String) -> String {
        guard let first = name.uppercased().first else { return "#" }
        if ("A"..."Z").contains(String(first)) { return String(first) }
        if ("0"..."9").contains(String(first)) { return "0-9" }
        return "#"
    }
}
