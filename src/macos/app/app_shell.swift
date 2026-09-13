import AppKit

final class PaneItem: Identifiable {
    let id: UInt32
    var title = "Terminal"
    let view = MosttyTerminalView(frame: .zero)

    init(id: UInt32) { self.id = id }
}

final class TabItem: Identifiable {
    let id = UUID()
    var title = "Terminal" { didSet { model?.tabBar?.refresh() } }
    weak var model: AppModel?
    let layout: OpaquePointer
    var panes: [PaneItem]
    lazy var host = PaneContainer(tab: self)
    var activePane: PaneItem? { panes.first { $0.id == mostty_layout_active(layout) } }
    var view: MosttyTerminalView { activePane!.view }

    init?(first: UInt32) {
        guard let layout = mostty_layout_create(first) else { return nil }
        self.layout = layout
        panes = [PaneItem(id: first)]
    }

    deinit { mostty_layout_destroy(layout) }
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

final class AppModel {
    static let shared = AppModel()

    var tabs: [TabItem] = [] { didSet { tabBar?.refresh() } }
    var selectedID: UUID? {
        didSet {
            container?.show(selectedTab?.host)
            tabBar?.refresh()
        }
    }
    var launchers: [TerminalLauncher] = []
    var themes: [String] = []
    var activeTheme = ""
    var tabbarFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { tabBar?.refresh() }
    }
    var tabbarHeight: CGFloat { max(28, ceil(tabbarFont.ascender - tabbarFont.descender + tabbarFont.leading) + 8) }
    private var confirmingClose = false
    private var lastPaneID: UInt32 = 0
    private let windowDelegate = TerminalWindowDelegate()

    var selectedTab: TabItem? { tabs.first { $0.id == selectedID } }

    /// The live terminal container, so a config reload can refresh the backdrop.
    weak var container: ContainerView?
    weak var tabBar: TabBar?
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
        for tab in tabs {
            for pane in tab.panes { pane.view.applyConfig() }
            tab.host.arrange()
        }
        container?.applyBackdrop()
        container?.applyWindowAppearance()
    }

    /// Applies one-shot `maximize` / `fullscreen` after showing the main window.
    /// ContainerView owns ongoing window state such as opacity.
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
        if let font = mostty_config_copy_tabbar_font() {
            tabbarFont = Unmanaged<NSFont>.fromOpaque(font).takeRetainedValue()
        }
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
        guard let id = nextPaneID(), let item = TabItem(first: id) else {
            showError("Unable to Open Tab", detail: "The terminal layout could not be created.")
            return
        }
        item.model = self
        configure(item.panes[0], in: item, launcher: launcher)
        tabs.append(item)
        selectedID = item.id
    }

    private func nextPaneID() -> UInt32? {
        guard lastPaneID < UInt32.max else { return nil }
        lastPaneID += 1
        return lastPaneID
    }

    private func configure(_ pane: PaneItem, in tab: TabItem, launcher: TerminalLauncher?) {
        pane.view.launcher = launcher
        pane.view.setAccessibilityLabel("Terminal pane \(pane.id)")
        pane.view.onTitleChange = { [weak tab, weak pane] title in
            guard let tab = tab, let pane = pane else { return }
            pane.title = title.isEmpty ? "Terminal" : title
            if tab.activePane === pane { tab.title = pane.title }
        }
        pane.view.onExit = { [weak self, weak tab, weak pane] in
            guard let tab = tab, let pane = pane else { return }
            self?.closePane(pane.id, in: tab, confirm: false)
        }
        pane.view.onFocus = { [weak self, weak tab, weak pane] in
            guard let self = self, let tab = tab, let pane = pane,
                  self.selectedID == tab.id, mostty_layout_focus(tab.layout, pane.id) else { return }
            tab.title = pane.title
            tab.host.needsDisplay = true
        }
    }

    func splitSelected(_ axis: UInt32, launcher: TerminalLauncher? = nil) {
        guard let tab = selectedTab, let active = tab.activePane else { return }
        tab.host.arrange()
        guard mostty_layout_can_split(tab.layout, active.id, axis), let id = nextPaneID() else {
            NSSound.beep()
            return
        }
        let pane = PaneItem(id: id)
        configure(pane, in: tab, launcher: launcher)
        // Start the owned session before publishing its ID to the model;
        // creation failure must preserve the current focus and maximization.
        tab.panes.append(pane)
        pane.view.frame = active.view.frame
        tab.host.addSubview(pane.view)
        guard pane.view.hasActiveSession else {
            tab.panes.removeLast()
            pane.view.removeFromSuperview()
            pane.view.shutdown()
            showError("Unable to Split Terminal", detail: "The new terminal session could not be started.")
            return
        }
        guard mostty_layout_split(tab.layout, active.id, id, axis) else {
            tab.panes.removeLast()
            pane.view.removeFromSuperview()
            pane.view.shutdown()
            NSSound.beep()
            return
        }
        tab.host.arrange()
        focusActivePane()
    }

    func focusDirection(_ direction: UInt32) {
        guard let tab = selectedTab, mostty_layout_direction(tab.layout, direction) else { return }
        tab.host.arrange()
        focusActivePane()
    }

    func togglePaneMaximize() {
        guard let tab = selectedTab else { return }
        mostty_layout_maximize(tab.layout)
        tab.host.arrange()
        focusActivePane()
    }

    func focusActivePane() {
        guard let tab = selectedTab, let pane = tab.activePane else { return }
        tab.title = pane.title
        tab.host.window?.makeFirstResponder(pane.view)
        tab.host.needsDisplay = true
    }

    func closeSelectedPane() {
        if let tab = selectedTab, let pane = tab.activePane { closePane(pane.id, in: tab) }
    }

    func closePane(_ id: UInt32, in tab: TabItem, confirm: Bool = true) {
        guard tabs.contains(where: { $0 === tab }), let pane = tab.panes.first(where: { $0.id == id }) else { return }
        if confirm, !confirmCloseViews([pane.view]) { return }
        guard tabs.contains(where: { $0 === tab }),
              let index = tab.panes.firstIndex(where: { $0.id == id }) else { return }
        if tab.panes.count == 1 {
            close(tab.id, confirm: false)
        } else if mostty_layout_close(tab.layout, id) {
            tab.panes.remove(at: index)
            pane.view.removeFromSuperview()
            pane.view.shutdown()
            tab.host.arrange()
            if selectedID == tab.id {
                focusActivePane()
            } else if let active = tab.activePane {
                tab.title = active.title
            }
        }
    }

    func closeSelected() {
        if let id = selectedID { close(id) }
    }

    func confirmClose(_ candidates: [TabItem]) -> Bool {
        confirmCloseViews(candidates.flatMap { $0.panes.map(\.view) })
    }

    private func confirmCloseViews(_ candidates: [MosttyTerminalView]) -> Bool {
        guard !confirmingClose else { return false }
        guard mostty_config_confirm_close(), candidates.contains(where: { $0.hasActiveSession }) else { return true }
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
        item.host.removeFromSuperview()
        for pane in item.panes { pane.view.shutdown() }
        if selectedID == id {
            selectedID = tabs.indices.contains(idx) ? tabs[idx].id : tabs.last?.id
        }
        if tabs.isEmpty { NSApplication.shared.terminate(nil) }
    }

    func shutdownAll() {
        for tab in tabs {
            tab.host.removeFromSuperview()
            for pane in tab.panes { pane.view.shutdown() }
        }
        tabs.removeAll()
    }
}

/// Preserve existing AppKit window callbacks while intercepting close requests.
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

/// Hosts the selected tab's persistent terminal view and restores its focus.
final class ContainerView: NSView {
    weak var model: AppModel?
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
        if let window = window { model?.installWindowDelegate(window) }
    }

    /// `background-opacity < 1` only shows through if the window itself stops
    /// painting an opaque background behind the Metal layer.
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
                guard let self = self, self.current === v else { return }
                self.model?.focusActivePane()
            }
        }
    }

    override func layout() {
        super.layout()
        backdrop?.frame = bounds
        current?.frame = bounds
        if let model = model {
            for tab in model.tabs {
                tab.host.frame = bounds
                tab.host.backingScale = window?.backingScaleFactor ?? tab.host.backingScale
                tab.host.arrange()
            }
        }
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

private enum TabPalette {
    static let bar = NSColor(srgbRed: 0x27 / 255.0, green: 0x2a / 255.0, blue: 0x32 / 255.0, alpha: 1)
    static let inactive = NSColor(srgbRed: 0x30 / 255.0, green: 0x33 / 255.0, blue: 0x3b / 255.0, alpha: 1)
    static let selected = NSColor(srgbRed: 0x4b / 255.0, green: 0x4e / 255.0, blue: 0x55 / 255.0, alpha: 1)
    static let border = NSColor(srgbRed: 0x66 / 255.0, green: 0x69 / 255.0, blue: 0x70 / 255.0, alpha: 1)
    static let hover = NSColor(srgbRed: 0x3a / 255.0, green: 0x3d / 255.0, blue: 0x45 / 255.0, alpha: 1)
    static let text = NSColor(srgbRed: 0xa4 / 255.0, green: 0xa5 / 255.0, blue: 0xaa / 255.0, alpha: 1)
}

/// AppKit retains button actions and accessibility; all chrome is drawn here.
class TabSymbolButton: NSButton {
    var isClose = false
    var showsSymbol = true { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        showsSymbol ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = hoverTracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard showsSymbol else { return }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        if !isClose || hovered || isHighlighted {
            (hovered || isHighlighted ? TabPalette.hover : TabPalette.bar).setFill()
            circle.fill()
        }
        if !isClose {
            TabPalette.hover.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
        let radius: CGFloat = isClose ? 3 : 5
        let x = bounds.midX, y = bounds.midY
        let glyph = NSBezierPath()
        if isClose {
            glyph.move(to: NSPoint(x: x - radius, y: y - radius))
            glyph.line(to: NSPoint(x: x + radius, y: y + radius))
            glyph.move(to: NSPoint(x: x - radius, y: y + radius))
            glyph.line(to: NSPoint(x: x + radius, y: y - radius))
        } else {
            glyph.move(to: NSPoint(x: x - radius, y: y))
            glyph.line(to: NSPoint(x: x + radius, y: y))
            glyph.move(to: NSPoint(x: x, y: y - radius))
            glyph.line(to: NSPoint(x: x, y: y + radius))
        }
        (hovered || isHighlighted ? NSColor.white : TabPalette.text).setStroke()
        glyph.lineWidth = 1.4
        glyph.lineCapStyle = .round
        glyph.stroke()
    }
}

final class LauncherMenuButton: TabSymbolButton {
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

final class TabBar: NSView {
    private let model: AppModel
    private var chips: [UUID: TabChipButton] = [:]
    private let launcher = LauncherMenuButton(frame: .zero)

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        model.tabBar = self
        launcher.configuredLaunchers = { [weak model] in model?.launchers ?? [] }
        launcher.openTab = { [weak model] launcher in model?.newTab(launcher: launcher) }
        addSubview(launcher)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func refresh() {
        let liveIDs = Set(model.tabs.map(\.id))
        for id in Array(chips.keys) where !liveIDs.contains(id) {
            chips.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, tab) in model.tabs.enumerated() {
            let button = chips[tab.id] ?? TabChipButton(frame: .zero)
            if chips[tab.id] == nil {
                chips[tab.id] = button
                addSubview(button)
                button.activateTab = { [weak model, weak tab] in
                    guard let tab = tab else { return }
                    model?.selectedID = tab.id
                }
                button.closeTab = { [weak model, weak tab] in
                    guard let tab = tab else { return }
                    model?.close(tab.id)
                }
            }
            button.title = tab.title
            button.selected = model.selectedID == tab.id
            button.number = index + 1
            button.titleFont = model.tabbarFont
            button.toolTip = tab.title
            button.setAccessibilityLabel(tab.title)
            button.setAccessibilityValue(button.selected ? 1 : 0)
            button.closeButton.setAccessibilityLabel("Close \(tab.title)")
            button.needsDisplay = true
        }
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    private var track: NSRect {
        NSRect(x: 10, y: 4, width: max(0, bounds.width - 54), height: model.tabbarHeight)
    }

    override func layout() {
        super.layout()
        let width = track.width / CGFloat(max(1, model.tabs.count))
        for (index, tab) in model.tabs.enumerated() {
            chips[tab.id]?.frame = NSRect(x: track.minX + CGFloat(index) * width, y: track.minY,
                                         width: width, height: track.height)
        }
        launcher.frame = NSRect(x: bounds.width - 38, y: track.midY - 14, width: 28, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        TabPalette.bar.setFill()
        bounds.fill()
        TabPalette.inactive.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }
}

final class TabChipButton: NSButton {
    var selected = false
    var number = 1
    var titleFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var activateTab: () -> Void = {}
    var closeTab: () -> Void = {}
    let closeButton = TabSymbolButton(frame: .zero)
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        target = self
        action = #selector(activate(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        // Expose one tab element with selection and close actions. Closing must
        // remain accessible even when the mouse-only close glyph is not shown.
        setAccessibilityChildren([])
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Close Tab", handler: { [weak self] in
            guard let self = self else { return false }
            self.closeTab()
            return true
        })])
        closeButton.isClose = true
        closeButton.showsSymbol = false
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.toolTip = "Close Tab"
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { false }
    // Long titles must never impose a minimum width on the equal-width strip.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: max(28, ceil(titleFont.ascender - titleFont.descender + titleFont.leading) + 8))
    }

    @objc private func activate(_ sender: Any?) { activateTab() }
    @objc private func close(_ sender: Any?) { closeTab() }

    override func accessibilityPerformPress() -> Bool {
        activateTab()
        return true
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 5, y: (bounds.height - 20) / 2, width: 20, height: 20)
        closeButton.isHidden = bounds.width < 50
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking = hoverTracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        closeButton.showsSymbol = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        closeButton.showsSymbol = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered || isHighlighted {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            (selected ? TabPalette.selected : TabPalette.hover).setFill()
            pill.fill()
            if selected {
                TabPalette.border.setStroke()
                pill.lineWidth = 1
                pill.stroke()
            }
        }
        let shortcut = number <= 9 && bounds.width >= 120 ? "⌘\(number)" : ""
        let side: CGFloat = shortcut.isEmpty ? 28 : 42
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = titleFont
        let textHeight = ceil(font.ascender - font.descender + font.leading)
        let rect = NSRect(x: side, y: (bounds.height - textHeight) / 2,
                          width: max(0, bounds.width - side * 2), height: textHeight)
        let foreground = selected ? NSColor(white: 0.95, alpha: 1) : TabPalette.text
        if rect.width > 0 {
            (title as NSString).draw(in: rect, withAttributes: [
                .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph])
        }
        if !shortcut.isEmpty {
            paragraph.alignment = .right
            let shortcutFont = NSFont.systemFont(ofSize: 11, weight: .medium)
            let shortcutHeight = ceil(shortcutFont.ascender - shortcutFont.descender)
            (shortcut as NSString).draw(in: NSRect(x: bounds.width - 38, y: (bounds.height - shortcutHeight) / 2, width: 28, height: shortcutHeight),
                                       withAttributes: [.font: shortcutFont,
                                                        .foregroundColor: foreground, .paragraphStyle: paragraph])
        }
    }
}

final class ContentView: NSView {
    private let model: AppModel
    private let tabBar: TabBar
    let terminal = ContainerView(frame: .zero)

    init(model: AppModel, frame: NSRect) {
        self.model = model
        tabBar = TabBar(model: model)
        super.init(frame: frame)
        terminal.model = model
        model.container = terminal
        addSubview(tabBar)
        addSubview(terminal)
        layout()
        terminal.show(model.selectedTab?.host)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func layout() {
        super.layout()
        let height = model.tabbarHeight + 8
        tabBar.frame = NSRect(x: 0, y: max(0, bounds.height - height), width: bounds.width, height: height)
        terminal.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - height))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var mainWindow: NSWindow?
    private let themeMenu = NSMenu(title: "Theme")

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.confirmClose(AppModel.shared.tabs) ? .terminateNow : .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdownAll() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenus()
        let model = AppModel.shared
        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Mostty"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 480, height: 300)
        window.contentView = ContentView(model: model, frame: frame)
        model.installWindowDelegate(window)
        mainWindow = window
        if !window.setFrameUsingName("main") { window.center() }
        window.setFrameAutosaveName("main")
        window.makeKeyAndOrderFront(nil)
        model.focusActivePane()
        NSApp.activate(ignoringOtherApps: true)
        model.applyInitialWindowState()
    }

    func installMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let menu = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        let app = submenu("Mostty")
        addItem(app, "About Mostty", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        addItem(app, "Open Configuration File", #selector(openConfig(_:)), key: ",")
        themeMenu.delegate = self
        let theme = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        theme.submenu = themeMenu
        app.addItem(theme)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        addItem(app, "Hide Mostty", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        addItem(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h",
                modifiers: [.command, .option], target: NSApp)
        addItem(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        addItem(app, "Quit Mostty", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)

        let file = submenu("File")
        addItem(file, "New Tab", #selector(newTab(_:)), key: "t")
        addItem(file, "Close Tab", #selector(closeTab(_:)), key: "w", modifiers: [.command, .shift])
        addItem(file, "Close Pane", #selector(closePane(_:)), key: "w")

        let edit = submenu("Edit")
        addItem(edit, "Undo", Selector(("undo:")), key: "z", responder: true)
        addItem(edit, "Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift], responder: true)
        edit.addItem(.separator())
        addItem(edit, "Cut", #selector(NSText.cut(_:)), key: "x", responder: true)
        addItem(edit, "Copy", #selector(MosttyTerminalView.copy(_:)), key: "c", responder: true)
        addItem(edit, "Paste", #selector(MosttyTerminalView.paste(_:)), key: "v", responder: true)
        addItem(edit, "Select All", #selector(NSText.selectAll(_:)), key: "a", responder: true)

        let tabs = submenu("Tabs")
        addItem(tabs, "Previous Tab", #selector(cycleTab(_:)), key: "{", modifiers: [.command, .shift], tag: -1)
        addItem(tabs, "Next Tab", #selector(cycleTab(_:)), key: "}", modifiers: [.command, .shift], tag: 1)
        tabs.addItem(.separator())
        for number in 1...9 {
            addItem(tabs, "Select Tab \(number)", #selector(selectTab(_:)), key: String(number), tag: number - 1)
        }

        let panes = submenu("Panes")
        addItem(panes, "Split Right", #selector(splitPane(_:)), key: "d", tag: 0)
        addItem(panes, "Split Down", #selector(splitPane(_:)), key: "d", modifiers: [.command, .shift], tag: 1)
        panes.addItem(.separator())
        for (index, entry) in [("Left", NSLeftArrowFunctionKey), ("Right", NSRightArrowFunctionKey),
                               ("Up", NSUpArrowFunctionKey), ("Down", NSDownArrowFunctionKey)].enumerated() {
            addItem(panes, "Focus \(entry.0)", #selector(focusPane(_:)), key: String(UnicodeScalar(entry.1)!),
                    modifiers: [.command, .option], tag: index)
        }
        panes.addItem(.separator())
        addItem(panes, "Maximize / Restore Pane", #selector(maximizePane(_:)), key: "\r", modifiers: [.command, .shift])

        let window = submenu("Window")
        addItem(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m", responder: true)
        addItem(window, "Zoom", #selector(NSWindow.performZoom(_:)), responder: true)
        addItem(window, "Toggle Full Screen", #selector(toggleFullscreen(_:)), key: "f", modifiers: [.command, .control])
        window.addItem(.separator())
        addItem(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                         modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0,
                         target: AnyObject? = nil, responder: Bool = false) {
        // AppKit matches the character produced with Shift held, including
        // uppercase letters; lowercase equivalents can select the plain action.
        let equivalent = modifiers.contains(.shift) ? key.uppercased() : key
        let item = NSMenuItem(title: title, action: action, keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        item.target = responder ? nil : (target ?? self)
        menu.addItem(item)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === themeMenu else { return }
        menu.removeAllItems()
        let model = AppModel.shared
        for bucket in Set(model.themes.map { themeBucket($0) }).sorted() {
            let group = NSMenu(title: bucket)
            let item = NSMenuItem(title: bucket, action: nil, keyEquivalent: "")
            item.submenu = group
            menu.addItem(item)
            for name in model.themes where themeBucket(name) == bucket {
                let theme = NSMenuItem(title: name, action: #selector(selectTheme(_:)), keyEquivalent: "")
                theme.target = self
                theme.state = name == model.activeTheme ? .on : .off
                group.addItem(theme)
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTab(_:)) {
            return AppModel.shared.tabs.indices.contains(menuItem.tag)
        }
        return true
    }

    @objc private func newTab(_ sender: NSMenuItem) { AppModel.shared.newTab() }
    @objc private func closeTab(_ sender: NSMenuItem) { AppModel.shared.closeSelected() }
    @objc private func closePane(_ sender: NSMenuItem) { AppModel.shared.closeSelectedPane() }
    @objc private func openConfig(_ sender: NSMenuItem) { AppModel.shared.openConfig() }
    @objc private func selectTheme(_ sender: NSMenuItem) { AppModel.shared.selectTheme(sender.title) }
    @objc private func cycleTab(_ sender: NSMenuItem) { AppModel.shared.cycleTab(sender.tag) }
    @objc private func selectTab(_ sender: NSMenuItem) { AppModel.shared.selectTab(at: sender.tag) }
    @objc private func splitPane(_ sender: NSMenuItem) { AppModel.shared.splitSelected(UInt32(sender.tag)) }
    @objc private func focusPane(_ sender: NSMenuItem) { AppModel.shared.focusDirection(UInt32(sender.tag)) }
    @objc private func maximizePane(_ sender: NSMenuItem) { AppModel.shared.togglePaneMaximize() }
    @objc private func toggleFullscreen(_ sender: NSMenuItem) { AppModel.shared.toggleFullscreen() }

    private func themeBucket(_ name: String) -> String {
        guard let first = name.uppercased().first else { return "#" }
        if ("A"..."Z").contains(String(first)) { return String(first) }
        if ("0"..."9").contains(String(first)) { return "0-9" }
        return "#"
    }
}

#if !MOSTTY_APP_TESTS
@main
struct MosttyApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
#endif
