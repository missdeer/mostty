import AppKit
import SwiftUI

private func testTabBar(_ model: AppModel, expect: (Bool, String) -> Void) {
    let first = model.tabs[0]
    first.title = "确认 Windows 和 macOS 标签栏渲染方式 | mostty"
    model.newTab()
    model.tabs[1].title = ":/Users/missdeer"
    model.selectTab(at: 0)
    let host = NSHostingView(rootView: TabBar(model: model))
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 36),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.level = .floating
    window.acceptsMouseMovedEvents = true
    window.orderFront(nil)
    let originalMouse = CGEvent(source: nil)?.location
    defer {
        window.orderOut(nil)
        if let point = originalMouse {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
    func settle() {
        let deadline = Date(timeIntervalSinceNow: 0.05)
        while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }
    func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                          timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil,
                          eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: 0)!
    }
    func click(_ view: NSView, at point: NSPoint) {
        let location = view.convert(point, to: nil)
        // NSButton's tracking loop consumes the queued mouse-up through AppKit.
        NSApp.postEvent(mouseEvent(.leftMouseUp, at: location), atStart: true)
        NSApp.sendEvent(mouseEvent(.leftMouseDown, at: location))
        settle()
    }
    func moveMouse(_ view: NSView, to point: NSPoint) {
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let location = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        settle()
    }
    func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
    func snapshot(_ name: String) {
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            expect(false, "tab bar can render to a bitmap")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/macos-interaction-tests/\(name).png")
        do { try bitmap.representation(using: .png, properties: [:])!.write(to: url) }
        catch { expect(false, "tab bar snapshot: \(error)") }
    }
    settle()
    let chips = descendants(host, of: TabChipButton.self).sorted {
        $0.convert($0.bounds, to: host).minX < $1.convert($1.bounds, to: host).minX
    }
    let plus = descendants(host, of: LauncherMenuButton.self).first!
    expect(chips[0].isAccessibilityElement() && chips[0].accessibilityRole() == .radioButton &&
           chips[0].accessibilityLabel() == first.title && chips[0].accessibilityChildren()?.isEmpty == true,
           "accessibility exposes a named tab instead of its underlying button cell")
    expect(chips.count == 2 && abs(chips[0].bounds.width - chips[1].bounds.width) < 1,
           "different title lengths receive equal tab widths")
    expect(chips[0].bounds.width > 500 && plus.convert(plus.bounds, to: host).maxX > 1180,
           "tabs fill the strip and the new-tab button stays at the trailing edge")
    expect(CGPreflightPostEventAccess(), "GUI test process is allowed to inject real pointer movement")
    moveMouse(host, to: NSPoint(x: -20, y: -20))
    snapshot("tabbar-normal")
    moveMouse(chips[0], to: NSPoint(x: 100, y: 14))
    expect(chips[0].closeButton.showsSymbol, "real pointer entry reveals the leading close control")
    snapshot("tabbar-hover")
    moveMouse(chips[0].closeButton, to: NSPoint(x: 10, y: 10))
    expect(chips[0].closeButton.showsSymbol, "crossing from the tab into its child close button preserves hover")
    moveMouse(host, to: NSPoint(x: -20, y: -20))
    expect(!chips[0].closeButton.showsSymbol, "real pointer exit hides the close glyph")
    click(chips[1], at: NSPoint(x: chips[1].bounds.midX, y: chips[1].bounds.midY))
    expect(model.selectedID == model.tabs[1].id && chips[1].selected,
           "self-drawn tab action selects the tab and updates its highlight")
    first.title = String(repeating: "长标题 / Long title ", count: 20)
    settle()
    expect(chips[0].title == first.title && abs(chips[0].bounds.width - chips[1].bounds.width) < 1,
           "live title updates reach the painter without expanding the tab")
    window.setContentSize(NSSize(width: 480, height: 36))
    settle()
    expect(abs(chips[0].bounds.width - chips[1].bounds.width) < 1 &&
           plus.convert(plus.bounds, to: host).maxX <= 480,
           "narrow windows keep equal tabs and the new-tab control inside the window")
    snapshot("tabbar-narrow")
    let close = chips[1].closeButton
    let point = NSPoint(x: close.frame.midX, y: close.frame.midY)
    model.selectTab(at: 0)
    settle()
    expect(chips[1].hitTest(chips[1].convert(point, to: chips[1].superview)) === chips[1],
           "an invisible close glyph does not intercept clicks intended to select a tab")
    click(chips[1], at: point)
    expect(model.tabs.count == 2 && model.selectedID == model.tabs[1].id,
           "window-dispatched clicks in the unhovered leading area select rather than close")
    moveMouse(close, to: NSPoint(x: close.bounds.midX, y: close.bounds.midY))
    expect(close.showsSymbol, "entering directly over the close control reveals it before the click")
    expect(chips[1].hitTest(chips[1].convert(point, to: chips[1].superview)) === close,
           "the visible close control receives clicks independently of tab activation")
    click(close, at: NSPoint(x: close.bounds.midX, y: close.bounds.midY))
    expect(model.tabs.count == 1 && model.selectedID == first.id,
           "self-drawn close control closes its own tab and preserves the remaining tab")
    moveMouse(host, to: NSPoint(x: -20, y: -20))
    click(plus, at: NSPoint(x: plus.bounds.midX, y: plus.bounds.midY))
    expect(model.tabs.count == 2 && model.selectedID == model.tabs.last?.id,
           "self-drawn plus opens and selects a new tab")
    expect(chips[0].accessibilityPerformPress() && model.selectedID == first.id,
           "accessibility press selects the tab without a pointer hover")
    settle()
    expect((chips[0].accessibilityValue() as? Int) == 1,
           "accessibility reports the newly selected tab state")
    let newChip = descendants(host, of: TabChipButton.self).first { $0 !== chips[0] }!
    expect(!newChip.closeButton.showsSymbol, "new tab starts with its mouse-only close glyph hidden")
    let closeAction = newChip.accessibilityCustomActions()?.first { $0.name == "Close Tab" }
    expect(closeAction?.handler?() == true && model.tabs.count == 1 && model.selectedID == first.id,
           "accessibility can close an unhovered background tab without selecting it")
    first.title = "Terminal"
}

private final class OriginalDelegate: NSObject, NSWindowDelegate {
    var closes = 0
    var allowsClose = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closes += 1
        return allowsClose
    }
    func windowDidResize(_ notification: Notification) {}
}

@main
struct InteractionTests {
    static func main() {
        _ = NSApplication.shared
        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        let model = AppModel.shared
        defer { model.shutdownAll() }
        testTabBar(model, expect: expect)
        for _ in 1..<9 { model.newTab() }
        for index in 0..<9 {
            model.selectTab(at: index)
            expect(model.selectedID == model.tabs[index].id, "numbered selection targets tab \(index + 1)")
        }
        model.cycleTab(1)
        expect(model.selectedID == model.tabs.first?.id, "next tab wraps from last to first")
        model.cycleTab(-1)
        expect(model.selectedID == model.tabs.last?.id, "previous tab wraps from first to last")
        let selected = model.selectedID
        model.selectTab(at: 9)
        model.selectTab(at: -1)
        expect(model.selectedID == selected, "out-of-range shortcuts preserve selection")
        expect(model.launchers.map(\.label) == ["First", "Second"], "launcher menu copies configured choices in order")
        let launcher = model.launchers[1]
        model.newTab(launcher: launcher)
        expect(model.selectedTab?.view.launcher?.command == "echo second" &&
               model.selectedTab?.view.launcher?.directory == "/var", "selected launcher preserves its command and directory")

        let sshURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/macos-interaction-tests/ssh-config")
        do {
            let source = "\u{feff}# Hosts\r\nHost alpha beta *.example !blocked ?pattern \"quoted\" # comment\r\n" +
                "  HostName ignored.example\n\thOsT\tgamma\nInclude ignored.conf\n"
            try Data(source.utf8).write(to: sshURL)
            let button = LauncherMenuButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            button.sshConfigURL = sshURL
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            let menu = button.menu(for: event)!
            expect(menu.items.map(\.title) == ["[SSH: alpha]", "[SSH: beta]", "[SSH: gamma]"],
                   "SSH-only configuration creates a menu with concrete Host aliases, excluding patterns and HostName")
            let menuWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 60),
                                      styleMask: [.titled], backing: .buffered, defer: false)
            menuWindow.contentView?.addSubview(button)
            menuWindow.orderFront(nil)
            var trackedMenu = false
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                  object: nil, queue: nil) { notification in
                guard let openedMenu = notification.object as? NSMenu else { return }
                trackedMenu = openedMenu.items.contains { $0.title == "[SSH: alpha]" }
                DispatchQueue.main.async { openedMenu.cancelTracking() }
            }
            let click = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 11, y: 11),
                                          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: menuWindow.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)!
            button.rightMouseDown(with: click)
            NotificationCenter.default.removeObserver(observer)
            menuWindow.orderOut(nil)
            expect(trackedMenu, "right-clicking the native plus button actually opens the SSH context menu")
            var chosen: TerminalLauncher?
            var opened = 0
            button.openTab = { chosen = $0; opened += 1 }
            menu.performActionForItem(at: 1)
            expect(chosen?.command == "ssh -- 'beta'" && chosen?.directory == "" && opened == 1,
                   "selecting an SSH menu item opens that host through the existing launcher path")
            button.performClick(nil)
            expect(chosen == nil && opened == 2, "left-click still requests the normal default tab")

            button.configuredLaunchers = { model.launchers }
            let mixed = button.menu(for: event)!
            expect(mixed.items.prefix(2).map(\.title) == ["First", "Second"] &&
                   mixed.items[2].isSeparatorItem && mixed.items[3].title == "[SSH: alpha]",
                   "configured launchers precede SSH hosts with a separator")
            try Data("Host updated\n".utf8).write(to: sshURL)
            expect(button.menu(for: event)?.items.last?.title == "[SSH: updated]",
                   "opening the menu reads SSH edits without restarting or reloading Mostty configuration")
            menu.performActionForItem(at: 1)
            expect(chosen?.command == "ssh -- 'beta'", "an open menu keeps its selected command snapshot")
            button.configuredLaunchers = { [] }
            try Data("Host * !excluded\n".utf8).write(to: sshURL)
            expect(button.menu(for: event) == nil, "patterns alone do not produce connectable menu entries")
            button.sshConfigURL = sshURL.appendingPathComponent("missing")
            expect(button.menu(for: event) == nil, "an unreadable SSH config leaves the menu empty")

            let host = "-oProxyCommand=$(id);'literal'"
            let escaped = SSHLaunchers.parse("Host \(host)\n")[0]
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "ssh() { printf '%s\\n' \"$@\"; }; " + escaped.command]
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            expect(process.terminationStatus == 0 && String(data: bytes, encoding: .utf8) == "--\n\(host)\n",
                   "SSH aliases remain one literal shell argument after --, including quotes and command syntax")
        } catch {
            expect(false, "SSH launcher regression: \(error)")
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let active = model.selectedTab!
        active.view.frame = window.contentView!.bounds
        window.contentView = active.view
        expect(active.view.hasActiveSession, "attached terminal has a running session")
        interaction_test_confirmation(true, false)
        model.closeSelected()
        expect(model.selectedID == active.id && interaction_test_alerts() == 1,
               "cancelling a tab close preserves the running session")
        expect(active.view.hasActiveSession && interaction_test_safe_close_default(),
               "tab confirmation puts Cancel first and never makes Close the Return-key default")
        let appDelegate = AppDelegate()
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateCancel,
               "application quit can be cancelled while sessions are active")
        expect(active.view.hasActiveSession && interaction_test_alerts() == 2 && interaction_test_safe_close_default(),
               "quit confirmation uses the same safe default and leaves the running session intact")

        let original = OriginalDelegate()
        window.delegate = original
        model.installWindowDelegate(window)
        let proxy = window.delegate!
        expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))),
               "window delegate preserves original resize callbacks")
        expect(proxy.windowShouldClose?(window) == false && original.closes == 0,
               "window close cancellation does not reach the original delegate")
        interaction_test_confirmation(true, true)
        expect(proxy.windowShouldClose?(window) == false && original.closes == 1 && active.view.hasActiveSession,
               "original delegate veto keeps sessions alive after confirmation")
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateNow,
               "confirmed application quit is allowed")

        interaction_test_confirmation(false, false)
        expect(model.confirmClose([active]) && interaction_test_alerts() == 0,
               "configuration can disable active-session confirmation")
        model.selectTheme("Light")
        expect(model.activeTheme == "Light", "theme menu tracks a successful live switch")
        model.selectTheme("Missing")
        expect(model.activeTheme == "Light", "failed theme load preserves the active theme")

        interaction_test_confirmation(true, true)
        model.close(active.id)
        expect(!model.tabs.contains { $0.id == active.id } && !active.view.hasActiveSession,
               "confirmed close shuts down the selected session")
        interaction_test_confirmation(true, false)
        let unstarted = model.tabs[0]
        model.close(unstarted.id)
        expect(!model.tabs.contains { $0.id == unstarted.id } && interaction_test_alerts() == 0,
               "a tab without an active session closes without confirmation")

        let remaining = Array(model.tabs.prefix(2))
        for tab in remaining {
            tab.view.frame = window.contentView!.bounds
            window.contentView = tab.view
        }
        expect(remaining.count == 2 && remaining.allSatisfy { $0.view.hasActiveSession },
               "window-close regression starts with two running sessions")
        original.allowsClose = true
        interaction_test_confirmation(true, false)
        let tabIDs = model.tabs.map(\.id)
        expect(proxy.windowShouldClose?(window) == false && model.tabs.map(\.id) == tabIDs &&
               remaining.allSatisfy { $0.view.hasActiveSession } && interaction_test_alerts() == 1,
               "cancelling window close preserves every tab and running session")
        expect(interaction_test_safe_close_default(),
               "window confirmation never makes Close the Return-key default")
        interaction_test_confirmation(true, true)
        expect(proxy.windowShouldClose?(window) == true && model.tabs.isEmpty &&
               remaining.allSatisfy { !$0.view.hasActiveSession } && interaction_test_alerts() == 1,
               "one accepted window confirmation shuts down every running session")
        expect(appDelegate.applicationShouldTerminate(NSApp) == .terminateNow && interaction_test_alerts() == 1,
               "quitting after accepted window closure does not ask for a second confirmation")
        model.cycleTab(1)
        expect(model.tabs.isEmpty, "cycling an empty tab list is harmless")

        let configURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tmp/macos-interaction-tests/Config")
        do {
            try Data("confirm-close-surface = false\n".utf8).write(to: configURL)
            interaction_test_config_path(configURL.path)
            var reloads = 0
            let watcher = ConfigWatcher { reloads += 1 }
            expect(watcher != nil, "configuration watcher attaches to the test file")
            try Data().write(to: configURL)
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            withExtendedLifetime(watcher) {
                expect(reloads > 0, "emptying configuration reloads defaults and restores close confirmation")
            }
        } catch {
            expect(false, "config reload regression: \(error)")
        }
        print("\(failures) interaction checks failed")
        exit(failures == 0 ? 0 : 1)
    }
}
