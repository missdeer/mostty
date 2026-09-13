import AppKit

private func testTabBar(_ model: AppModel, expect: (Bool, String) -> Void) {
    let first = model.tabs[0]
    first.title = "确认 Windows 和 macOS 标签栏渲染方式 | mostty"
    model.newTab()
    model.tabs[1].title = ":/Users/missdeer"
    model.selectTab(at: 0)
    let host = TabBar(model: model)
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
    let originalFont = model.tabbarFont
    model.tabbarFont = NSFont(name: "Courier New", size: 30)!
    window.setContentSize(NSSize(width: 1200, height: model.tabbarHeight + 8))
    settle()
    expect(chips.allSatisfy { $0.titleFont.familyName == "Courier New" && $0.titleFont.pointSize == 30 },
           "live tabbar font changes reach every tab title")
    expect(chips[0].bounds.height >= ceil(model.tabbarFont.ascender - model.tabbarFont.descender + model.tabbarFont.leading),
           "large configured tabbar fonts expand the strip without clipping")
    snapshot("tabbar-large-font")
    model.tabbarFont = originalFont
    window.setContentSize(NSSize(width: 1200, height: model.tabbarHeight + 8))
    settle()
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

private func testAppShell(_ model: AppModel, expect: (Bool, String) -> Void) {
    let delegate = AppDelegate()
    let originalMenu = NSApp.mainMenu
    let originalWindowsMenu = NSApp.windowsMenu
    let originalServicesMenu = NSApp.servicesMenu
    let frameKey = "NSWindow Frame main"
    let originalFrame = UserDefaults.standard.object(forKey: frameKey)
    NSWindow.removeFrame(usingName: "main")
    defer {
        UserDefaults.standard.set(originalFrame, forKey: frameKey)
    }
    model.newTab()
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    guard let content = model.container?.superview as? ContentView, let window = content.window else {
        expect(false, "AppKit launch creates the terminal content and its window")
        model.shutdownAll()
        return
    }
    defer {
        window.orderOut(nil)
        window.setFrameAutosaveName("")
        model.shutdownAll()
        window.contentView = nil
        NSApp.mainMenu = originalMenu
        NSApp.windowsMenu = originalWindowsMenu
        NSApp.servicesMenu = originalServicesMenu
        withExtendedLifetime(delegate) {}
    }
    func settle() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        content.layoutSubtreeIfNeeded()
    }
    func shortcut(_ key: String, modifiers: NSEvent.ModifierFlags = .command) -> Bool {
        let characters = modifiers.contains(.shift) ? key.uppercased() : key
        let keyCodes: [String: UInt16] = ["t": 17, "1": 18, "d": 2, "w": 13, "f": 3, "\r": 36, "{": 33, "}": 30,
                                         String(UnicodeScalar(NSLeftArrowFunctionKey)!): 123,
                                         String(UnicodeScalar(NSRightArrowFunctionKey)!): 124,
                                         String(UnicodeScalar(NSDownArrowFunctionKey)!): 125,
                                         String(UnicodeScalar(NSUpArrowFunctionKey)!): 126]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil,
                                    characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: keyCodes[key]!)!
        return NSApp.mainMenu!.performKeyEquivalent(with: event)
    }
    func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 8)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        return condition()
    }
    settle()
    let first = model.selectedTab!
    expect(window.isVisible && window.firstResponder === first.view && first.view.hasActiveSession,
           "AppKit launch displays a running terminal with keyboard focus")
    expect(window.appearance?.name == .darkAqua && window.tabbingMode == .disallowed &&
           window.contentMinSize.width >= 480 && window.contentMinSize.height >= 300,
           "native window preserves dark chrome, custom tabs, and terminal minimum dimensions")
    expect(window.collectionBehavior.contains(.fullScreenPrimary), "main window explicitly supports native fullscreen")
    expect(shortcut("t") && model.tabs.count == 2, "native Command-T menu shortcut creates a tab")
    settle()
    let second = model.selectedTab!
    expect(first.host.superview == nil && second.host.superview === content.terminal &&
           window.firstResponder === second.view && first.view.hasActiveSession,
           "tab selection swaps persistent hosts and restores focus without stopping the background session")
    expect(shortcut("1") && model.selectedID == first.id, "native numbered shortcut selects the requested tab")
    settle()
    expect(window.firstResponder === first.view, "numbered tab selection restores the selected pane's first responder")
    expect(shortcut("}", modifiers: [.command, .shift]) && model.selectedID == second.id,
           "native Command-Shift-] selects the next tab")
    expect(shortcut("{", modifiers: [.command, .shift]) && model.selectedID == first.id,
           "native Command-Shift-[ selects the previous tab")
    settle()
    let tabsMenu = NSApp.mainMenu!.item(withTitle: "Tabs")!.submenu!
    tabsMenu.update()
    expect(tabsMenu.item(withTitle: "Select Tab 2")!.isEnabled &&
           !tabsMenu.item(withTitle: "Select Tab 3")!.isEnabled,
           "native menus disable numbered shortcuts for tabs that do not exist")

    let left = first.activePane!
    expect(shortcut("d") && first.panes.count == 2, "native Command-D splits the active pane to the right")
    let right = first.activePane!
    expect(right !== left && right.view.frame.minX > left.view.frame.minX,
           "split-right shortcut creates and focuses a pane on the right")
    expect(shortcut("d", modifiers: [.command, .shift]) && first.panes.count == 3,
           "native Command-Shift-D splits the active pane downwards")
    let bottom = first.activePane!
    expect(bottom !== right && bottom.view.frame.minY > right.view.frame.minY,
           "split-down shortcut creates and focuses a pane below its source")
    for (key, target) in [(NSUpArrowFunctionKey, right), (NSDownArrowFunctionKey, bottom),
                           (NSLeftArrowFunctionKey, left), (NSRightArrowFunctionKey, right)] {
        expect(shortcut(String(UnicodeScalar(key)!), modifiers: [.command, .option]) &&
               first.activePane === target && window.firstResponder === target.view,
               "native directional shortcut focuses the adjacent pane and its input responder")
    }
    expect(shortcut("\r", modifiers: [.command, .shift]) && mostty_layout_panes(first.layout, nil, 0) == 1,
           "native Command-Shift-Return maximizes the active pane")
    expect(shortcut("\r", modifiers: [.command, .shift]) && mostty_layout_panes(first.layout, nil, 0) == 3,
           "native Command-Shift-Return restores all split panes")
    interaction_test_confirmation(false, false)
    expect(shortcut("w") && first.panes.count == 2 && !right.view.hasActiveSession && second.view.hasActiveSession,
           "native Command-W closes only the focused pane and preserves background tabs")

    var enteredFullscreen = false
    var exitedFullscreen = false
    let entered = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                          object: window, queue: nil) { _ in enteredFullscreen = true }
    let exited = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                         object: window, queue: nil) { _ in exitedFullscreen = true }
    defer {
        NotificationCenter.default.removeObserver(entered)
        NotificationCenter.default.removeObserver(exited)
    }
    expect(shortcut("f", modifiers: [.command, .control]) && waitUntil { enteredFullscreen } &&
           window.styleMask.contains(.fullScreen),
           "native Control-Command-F completes the transition into a fullscreen Space")
    if window.styleMask.contains(.fullScreen) {
        expect(shortcut("f", modifiers: [.command, .control]) && waitUntil { exitedFullscreen } &&
               !window.styleMask.contains(.fullScreen),
               "native Control-Command-F completes the transition back to a normal window")
    }

    let font = model.tabbarFont
    model.tabbarFont = NSFont.monospacedSystemFont(ofSize: 30, weight: .regular)
    window.setContentSize(NSSize(width: 740, height: 520))
    settle()
    expect(abs(content.terminal.frame.maxY + model.tabbarHeight + 8 - content.bounds.height) < 1 &&
           content.terminal.bounds.width == content.bounds.width && first.host.frame == content.terminal.bounds,
           "window resizing and live tab fonts reserve the full chrome height above the terminal")
    model.tabbarFont = font
    model.reloadConfig()
    let themeMenu = NSApp.mainMenu!.items[0].submenu!.item(withTitle: "Theme")!.submenu!
    delegate.menuNeedsUpdate(themeMenu)
    let light = themeMenu.item(withTitle: "L")!.submenu!
    light.performActionForItem(at: 0)
    expect(model.activeTheme == "Light", "native theme menu actions apply the selected theme")
    model.selectTheme("Dark")
    delegate.menuNeedsUpdate(themeMenu)
    expect(themeMenu.item(withTitle: "D")!.submenu!.items[0].state == .on &&
           themeMenu.item(withTitle: "L")!.submenu!.items[0].state == .off,
           "reopening the native theme menu reflects the current theme after external model changes")
    interaction_test_confirmation(false, false)
    expect(shortcut("w", modifiers: [.command, .shift]) && model.tabs.count == 1 && !first.view.hasActiveSession,
           "native Command-Shift-W closes the selected tab and stops its session")
    settle()
    expect(model.selectedID == second.id && window.firstResponder === second.view,
           "closing the selected tab restores the surviving terminal's focus")

    window.miniaturize(nil)
    expect(waitUntil { window.isMiniaturized }, "terminal window can be minimized before a Dock reopen")
    do {
        // The Dock delivers kAEReopenApplication to the application itself.
        let reopen = NSAppleEventDescriptor(eventClass: 0x61657674, eventID: 0x72617070,
                                            targetDescriptor: .currentProcess(), returnID: -1, transactionID: 0)
        try reopen.sendEvent(options: .noReply, timeout: 1)
        expect(waitUntil { !window.isMiniaturized && window.isVisible },
               "AppKit's default Dock reopen restores the minimized main window")
    } catch {
        expect(false, "Dock reopen event could not be delivered: \(error)")
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    settle()

    let screen = window.screen!.visibleFrame
    window.setFrameOrigin(NSPoint(x: screen.minX + 40, y: screen.minY + 60))
    settle()
    let savedFrame = window.frame
    expect(window.frameAutosaveName == "main" && UserDefaults.standard.string(forKey: frameKey) != nil,
           "moving and resizing the main window automatically saves its normal frame")
    window.orderOut(nil)
    window.setFrameAutosaveName("")
    window.contentView = nil
    model.shutdownAll()
    model.newTab()

    let restoredDelegate = AppDelegate()
    var startupEntered = false
    var startupExited = false
    let startupEntry = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                                              object: nil, queue: nil) { _ in startupEntered = true }
    let startupExit = NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                             object: nil, queue: nil) { _ in startupExited = true }
    interaction_test_fullscreen(true)
    defer {
        interaction_test_fullscreen(false)
        NotificationCenter.default.removeObserver(startupEntry)
        NotificationCenter.default.removeObserver(startupExit)
        if let restored = model.container?.window {
            restored.orderOut(nil)
            restored.setFrameAutosaveName("")
            restored.contentView = nil
        }
        withExtendedLifetime(restoredDelegate) {}
    }
    restoredDelegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let restored = model.container!.window!
    expect(waitUntil { startupEntered } && restored.styleMask.contains(.fullScreen),
           "fullscreen configuration completes a native fullscreen transition during application launch")
    if restored.styleMask.contains(.fullScreen) {
        restored.toggleFullScreen(nil)
        expect(waitUntil { startupExited }, "startup fullscreen can return to a normal window")
    }
    expect(abs(restored.frame.minX - savedFrame.minX) < 1 && abs(restored.frame.minY - savedFrame.minY) < 1 &&
           abs(restored.frame.width - savedFrame.width) < 1 && abs(restored.frame.height - savedFrame.height) < 1,
           "relaunch restores the saved position and size, including after leaving startup fullscreen")
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
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
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
        active.host.frame = window.contentLayoutRect
        window.contentView = active.host
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
            tab.host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
            window.contentView = tab.host
            tab.host.arrange()
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
        testAppShell(model, expect: expect)

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
