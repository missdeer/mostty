import AppKit
import QuartzCore
import Metal

private final class PaneScrollEvent: NSEvent {
    var point = NSPoint.zero
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { 1000 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

@main
struct PaneTests {
    static func main() throws {
        exit(try run())
    }

    private static func run() throws -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = root.appendingPathComponent("tmp/macos-pane-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configReload = CommandLine.arguments.contains("--config-reload")
        var configURL: URL?
        var originalConfig: Data?
        var lastConfig: Data?
        func writeConfig(_ source: String) throws {
            guard let url = configURL else { return }
            let data = Data(source.utf8)
            try data.write(to: url, options: .atomic)
            lastConfig = data
        }
        func restoreConfig() throws {
            guard let url = configURL, let last = lastConfig else { return }
            guard try Data(contentsOf: url) == last else {
                throw NSError(domain: "PaneTests", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Configuration changed externally during the test; preserved the external edit and the backup."])
            }
            if let original = originalConfig { try original.write(to: url, options: .atomic) }
            else { try FileManager.default.removeItem(at: url) }
            lastConfig = nil
        }
        if configReload {
            var path = [UInt8](repeating: 0, count: 4096)
            let count = mostty_config_path(&path, path.count)
            guard count > 0 else { throw NSError(domain: "PaneTests", code: 2) }
            let url = URL(fileURLWithPath: String(decoding: path.prefix(count), as: UTF8.self))
            configURL = url
            if FileManager.default.fileExists(atPath: url.path) {
                originalConfig = try Data(contentsOf: url)
                let backup = directory.appendingPathComponent("config-backup-\(UUID().uuidString)")
                try originalConfig!.write(to: backup, options: .withoutOverwriting)
                print("Config backup: \(backup.path)")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeConfig("font-family = Menlo\nfont-size = 12\nbackground = #101820\nbackground-opacity = 1\nbackground-blur = false\n")
        }
        defer {
            do { try restoreConfig() }
            catch { fputs("Configuration restoration needs attention: \(error)\n", stderr) }
        }
        let model = AppModel.shared
        defer { model.shutdownAll() }
        let window = NSWindow(contentRect: NSRect(x: 60, y: 80, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Mostty pane acceptance"
        let container = ContainerView(frame: window.contentView!.bounds)
        container.model = model
        model.container = container
        window.contentView = container
        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        func settle(_ seconds: Double = 0.15) {
            let until = Date().addingTimeInterval(seconds)
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                window.contentView?.layoutSubtreeIfNeeded()
            } while Date() < until
        }
        func launcher(_ name: String) -> TerminalLauncher {
            TerminalLauncher(label: name,
                command: "python3 -u tests/macos/pane-client.py \(name) tmp/macos-pane-tests",
                directory: root.path)
        }
        func input(_ pane: PaneItem, _ text: String) {
            window.makeFirstResponder(pane.view)
            pane.view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func received(_ name: String) -> String {
            (try? String(contentsOf: directory.appendingPathComponent(name + ".input"), encoding: .utf8)) ?? ""
        }
        func showSelected() {
            container.show(model.selectedTab?.host)
            container.needsLayout = true
            settle()
            model.focusActivePane()
        }
        let initial = model.tabs[0]
        model.newTab(launcher: launcher("one"))
        model.close(initial.id, confirm: false)
        let tab = model.selectedTab!
        showSelected()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.splitSelected(0, launcher: launcher("two"))
        model.focusDirection(0)
        model.splitSelected(1, launcher: launcher("three"))
        model.focusDirection(1)
        model.splitSelected(1, launcher: launcher("four"))
        settle(1)
        expect(tab.panes.count == 4 && tab.panes.allSatisfy { $0.view.hasActiveSession },
               "four mixed-direction panes run independent real PTYs")
        guard tab.panes.count == 4 else { return 1 }
        let panes = tab.panes
        let sessions = panes.map { $0.view.testSession }
        let pids = panes.map { $0.title.split(separator: ":").dropFirst().first.map(String.init) ?? "" }
        expect(Set(pids).count == 4 && !pids.contains(""), "all four shells report distinct process IDs")
        for (index, pane) in panes.enumerated() { input(pane, "input-\(index)-中文\n") }
        settle()
        for (index, name) in ["one", "two", "three", "four"].enumerated() {
            expect(received(name) == "input-\(index)-中文\n", "Unicode input reaches only \(name)")
        }
        func dimensionsMatch() -> Bool {
            panes.allSatisfy { pane in
                guard let session = pane.view.testSession else { return false }
                let fields = pane.title.split(separator: ":")
                guard fields.count == 4, let rows = UInt32(fields[2]), let cols = UInt32(fields[3]) else { return false }
                var cw: UInt32 = 0, ch: UInt32 = 0
                mostty_tab_cell_size(session, &cw, &ch)
                let surface = pane.view.subviews.first { $0.layer is CAMetalLayer }!
                let layer = surface.layer as! CAMetalLayer
                let matches = cols == max(1, UInt32(layer.drawableSize.width) / cw) &&
                    rows == max(1, UInt32(layer.drawableSize.height) / ch - 1)
                if !matches { print("SIZE: \(pane.title) drawable=\(layer.drawableSize) cell=\(cw)x\(ch)") }
                return matches
            }
        }
        expect(dimensionsMatch(), "each real PTY reports rows and columns matching its own Metal drawable")
        func pixels(_ pane: PaneItem) throws -> (bytes: [UInt8], width: Int, height: Int) {
            var cols: UInt32 = 0, rows: UInt32 = 0
            guard let pointer = mostty_tab_render(pane.view.testSession!, false, &cols, &rows),
                  let texture = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? MTLTexture,
                  let buffer = texture.device.makeBuffer(length: texture.width * texture.height * 4, options: .storageModeShared),
                  let command = texture.device.makeCommandQueue()?.makeCommandBuffer(),
                  let blit = command.makeBlitCommandEncoder() else { throw NSError(domain: "PanePixels", code: 1) }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: texture.width * 4,
                      destinationBytesPerImage: texture.width * texture.height * 4)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw NSError(domain: "PanePixels", code: 2) }
            return (Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length)),
                    texture.width, texture.height)
        }
        func center(_ pane: PaneItem) throws -> [UInt8] {
            let image = try pixels(pane)
            let offset = ((image.height / 2) * image.width + image.width / 2) * 4
            return Array(image.bytes[offset..<offset + 4])
        }
        var visible = [MosttyLayoutPane](repeating: MosttyLayoutPane(), count: 4)
        _ = mostty_layout_panes(tab.layout, &visible, visible.count)
        let edge = visible[0].rect.x + visible[0].rect.width
        func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: tab.host.convert(NSPoint(x: x, y: y), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let active = mostty_layout_active(tab.layout)
        tab.host.mouseDown(with: mouse(.leftMouseDown, x: edge + 2, y: 20))
        tab.host.mouseDragged(with: mouse(.leftMouseDragged, x: 360, y: 20))
        tab.host.mouseUp(with: mouse(.leftMouseUp, x: 360, y: 20))
        settle()
        expect(mostty_layout_active(tab.layout) == active && dimensionsMatch() &&
               panes[0].view.bounds.width < panes[1].view.bounds.width,
               "native divider drag changes independent PTY sizes during output and preserves focus")
        tab.host.mouseDown(with: mouse(.leftMouseDown, x: 360, y: 20))
        tab.host.mouseDragged(with: mouse(.leftMouseDragged, x: -1000, y: 20))
        tab.host.mouseUp(with: mouse(.leftMouseUp, x: -1000, y: 20))
        settle()
        expect(panes[0].view.bounds.width >= panes[0].view.minimumPaneSize.width &&
               panes[2].view.bounds.width >= panes[2].view.minimumPaneSize.width && dimensionsMatch(),
               "divider capture clamps both nested panes to their terminal minimum size")
        _ = mostty_layout_panes(tab.layout, &visible, visible.count)
        let clampedEdge = visible[0].rect.x + visible[0].rect.width
        tab.host.mouseDown(with: mouse(.leftMouseDown, x: clampedEdge + 2, y: 20))
        tab.host.mouseDragged(with: mouse(.leftMouseDragged, x: 360, y: 20))
        tab.host.mouseUp(with: mouse(.leftMouseUp, x: 360, y: 20))
        window.setContentSize(NSSize(width: 1000, height: 650))
        settle()
        expect(dimensionsMatch(), "window resize reflows all live PTYs while output continues")
        let restoredSize = window.contentLayoutRect.size
        window.setContentSize(window.contentMinSize)
        settle()
        expect(panes.allSatisfy { $0.view.bounds.width >= $0.view.minimumPaneSize.width &&
                   $0.view.bounds.height >= $0.view.minimumPaneSize.height } && dimensionsMatch(),
               "native minimum window size preserves every nested pane's terminal minimum")
        window.makeFirstResponder(panes[0].view)
        model.togglePaneMaximize()
        let focusedBeforeRefusal = mostty_layout_active(tab.layout)
        model.splitSelected(0, launcher: launcher("refused"))
        expect(tab.panes.count == 4 && tab.host.subviews.count == 1 &&
                   mostty_layout_active(tab.layout) == focusedBeforeRefusal && panes.map { $0.view.testSession } == sessions,
               "too-small split while maximized preserves the saved layout, focus, and sessions")
        model.togglePaneMaximize()
        window.setContentSize(restoredSize)
        settle()
        let frames = panes.map { $0.view.frame }
        model.togglePaneMaximize()
        settle()
        expect(tab.host.subviews.count == 1 && panes.map { $0.view.testSession } == sessions,
               "maximize detaches other views without recreating any session")
        model.focusDirection(0)
        expect(window.firstResponder === tab.activePane?.view, "directional focus while maximized updates firstResponder")
        model.togglePaneMaximize()
        settle()
        expect(panes.map { $0.view.frame } == frames && dimensionsMatch(), "restore preserves the saved divider ratio and PTY geometry")
        model.newTab(launcher: launcher("background"))
        showSelected()
        let other = model.selectedTab!
        let titles = panes.map(\.title)
        let beforeHistory = mostty_tab_scrollbar(panes[0].view.testSession!).total
        settle(0.3)
        expect(panes.allSatisfy { $0.view.hasActiveSession } && panes.map { $0.view.testSession } == sessions,
               "switching tabs preserves all hidden sessions")
        expect(mostty_tab_scrollbar(panes[0].view.testSession!).total > beforeHistory,
               "hidden-tab readers continue feeding new output into VT scrollback")
        if configReload {
            func cellHeight(_ pane: PaneItem) -> UInt32 {
                var width: UInt32 = 0, height: UInt32 = 0
                mostty_tab_cell_size(pane.view.testSession!, &width, &height)
                return height
            }
            let beforeCells = panes.map(cellHeight)
            let visibleBefore = cellHeight(other.panes[0])
            let theme = directory.appendingPathComponent("reload-theme")
            try Data("background = #204060\nforeground = #ffffff\n".utf8).write(to: theme)
            try writeConfig("font-family = Menlo\nfont-size = 18\ntheme = \(theme.path)\nbackground-opacity = 0.5\nbackground-blur = true\n")
            settle(1)
            expect(zip(panes.map(cellHeight), beforeCells).allSatisfy { $0 > $1 } &&
                   cellHeight(other.panes[0]) > visibleBefore && dimensionsMatch(),
                   "file watcher applies changed font metrics and PTY dimensions to visible and hidden panes")
            expect(model.activeTheme == theme.path && panes.map { $0.view.testSession } == sessions,
                   "file watcher changes theme without replacing hidden sessions")
            for pane in panes { input(pane, "C") }
            settle()
            for pane in panes {
                let color = try center(pane)
                expect(abs(Int(color[0]) - 48) <= 1 && abs(Int(color[1]) - 32) <= 1 &&
                       abs(Int(color[2]) - 16) <= 1 && abs(Int(color[3]) - 128) <= 1,
                       "reloaded theme and opacity reach hidden pane \(pane.id)'s premultiplied Metal pixels")
            }
            expect(!window.isOpaque && container.subviews.contains { $0 is NSVisualEffectView } &&
                   panes.allSatisfy { !$0.view.isOpaque },
                   "transparent pane layers retain a shared native blur backdrop behind the selected tab")
            for pane in panes { input(pane, "R") }
            try writeConfig("font-family = Menlo\nfont-size = 12\nbackground = #101820\nbackground-opacity = 1\nbackground-blur = false\n")
            settle(1)
            expect(panes.map(cellHeight) == beforeCells && window.isOpaque &&
                   !container.subviews.contains { $0 is NSVisualEffectView } && dimensionsMatch(),
                   "restoring opaque font settings updates all panes and removes the blur backdrop")
        }
        model.selectedID = tab.id
        showSelected()
        expect(panes.map(\.title) == titles && panes.map { $0.view.testSession } == sessions,
               "returning to a tab restores its sessions and identities")
        model.close(other.id, confirm: false)
        for pane in panes {
            let candidate = pane.view.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            let screen = window.convertToScreen(pane.view.convert(pane.view.bounds, to: nil))
            expect(screen.contains(candidate), "IME candidate anchor stays inside pane \(pane.id) in screen coordinates")
        }
        window.makeFirstResponder(panes[2].view)
        panes[2].view.setMarkedText("输入法", selectedRange: NSRange(location: 3, length: 0),
                                    replacementRange: NSRange(location: NSNotFound, length: 0))
        window.makeFirstResponder(panes[1].view)
        settle()
        expect(received("three").contains("输入法") && !received("two").contains("输入法") && !panes[2].view.hasMarkedText(),
               "changing focus commits pending composition to its original pane")
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        func restorePasteboard() {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { entries in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            })
        }
        defer { restorePasteboard() }
        input(panes[1], "B")
        settle()
        pasteboard.clearContents()
        pasteboard.setString("pane paste\nsecond line", forType: .string)
        panes[1].view.paste(nil)
        settle()
        expect(received("two").contains("\u{1b}[200~pane paste\rsecond line\u{1b}[201~") &&
               !received("one").contains("pane paste"), "bracketed clipboard paste reaches only its target pane")
        let selected = panes[2]
        let top = selected.view.bounds.height - 8
        let startPoint = selected.view.convert(NSPoint(x: 2, y: top), to: tab.host)
        let endPoint = selected.view.convert(NSPoint(x: 110, y: top), to: tab.host)
        selected.view.mouseDown(with: mouse(.leftMouseDown, x: startPoint.x, y: startPoint.y))
        selected.view.mouseDragged(with: mouse(.leftMouseDragged, x: endPoint.x, y: endPoint.y))
        selected.view.mouseUp(with: mouse(.leftMouseUp, x: endPoint.x, y: endPoint.y))
        expect(pasteboard.string(forType: .string)?.contains("three") == true,
               "pane-local selection copies the selected session's output")
        let previousScroll = mostty_tab_scrollbar(panes[1].view.testSession!)
        let wheel = PaneScrollEvent()
        wheel.point = selected.view.convert(NSPoint(x: 20, y: 20), to: nil)
        selected.view.scrollWheel(with: wheel)
        let scroll = mostty_tab_scrollbar(selected.view.testSession!)
        let untouched = mostty_tab_scrollbar(panes[1].view.testSession!)
        expect(scroll.offset == 0 && scroll.total > scroll.visible && untouched.offset == previousScroll.offset,
               "scroll input changes only the selected pane's viewport")
        // Exercise backing-scale transitions with the same persistent native
        // views, independently of whether this machine has two physical screens.
        container.show(nil)
        tab.host.backingScale = 1
        tab.host.arrange()
        settle()
        expect(dimensionsMatch() && panes.map { $0.view.testSession } == sessions,
               "1x backing-scale reflow preserves sessions and independent PTY geometry")
        tab.host.backingScale = 2
        tab.host.arrange()
        settle()
        expect(dimensionsMatch() && panes.map { $0.view.testSession } == sessions,
               "2x backing-scale reflow preserves sessions and independent PTY geometry")
        showSelected()
        restorePasteboard()
        input(panes[0], "M")
        settle()
        let point = panes[0].view.convert(NSPoint(x: 30, y: panes[0].view.bounds.height - 25), to: tab.host)
        panes[0].view.mouseDown(with: mouse(.leftMouseDown, x: point.x, y: point.y))
        panes[0].view.mouseUp(with: mouse(.leftMouseUp, x: point.x, y: point.y))
        settle()
        expect(received("one").contains("\u{1b}[<0;") && !received("two").contains("\u{1b}[<"),
               "pane-local SGR mouse reports reach only the clicked session")
        input(panes[0], "C")
        input(panes[1], "C")
        settle()
        let neighboringBackground = try center(panes[0])
        input(panes[1], "G")
        settle()
        expect(try center(panes[1]) == [0, 0, 255, 255] && center(panes[0]) == neighboringBackground,
               "oversized Kitty placement renders red pixels only in its owning pane's texture")
        let surface = panes[1].view.subviews.first { $0.layer is CAMetalLayer }!
        expect(tab.host.bounds.contains(panes[1].view.frame) && panes[1].view.bounds.contains(surface.frame) && dimensionsMatch(),
               "Kitty drawable remains within the native pane bounds after resize and scale changes")
        let siblingHeight = panes[1].view.frame.height
        input(panes[3], "\u{4}")
        settle(0.5)
        expect(tab.panes.count == 3 && !panes[3].view.hasActiveSession && tab.panes.allSatisfy { $0.view.hasActiveSession },
               "one shell exit closes only its pane and keeps sibling readers alive")
        expect(panes[1].view.frame.height > siblingHeight && panes[1].view.testSession == sessions[1],
               "closing a pane expands its surviving sibling without replacing the sibling session")
        model.newTab(launcher: launcher("last"))
        showSelected()
        let lastTab = model.selectedTab!
        let lastPane = lastTab.panes[0]
        input(lastPane, "\u{4}")
        settle(0.5)
        expect(!model.tabs.contains { $0 === lastTab } && !lastPane.view.hasActiveSession && model.selectedID == tab.id,
               "last-pane shell exit removes only that tab and selects the surviving tab")
        showSelected()
        let survivors = tab.panes
        let start = Date()
        model.shutdownAll()
        expect(Date().timeIntervalSince(start) < 3 && survivors.allSatisfy { !$0.view.hasActiveSession },
               "window shutdown stops every real background reader without hanging")
        for pane in survivors {
            pane.view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            container.addSubview(pane.view)
        }
        expect(survivors.allSatisfy { $0.view.testSession == nil }, "closed views cannot restart shells during late native layout callbacks")
        window.orderOut(nil)
        try restoreConfig()
        print("\(failures) native pane checks failed")
        return failures == 0 ? 0 : 1
    }
}
