import AppKit

private final class MouseWheelEvent: NSEvent {
    var point = NSPoint.zero
    var delta = 0.0
    var horizontalDelta = 0.0
    var precise = false
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { horizontalDelta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

private final class KeypadEvent: NSEvent {
    var code: UInt16 = 0
    var flags: NSEvent.ModifierFlags = .numericPad
    var text = ""
    override var type: NSEvent.EventType { .keyDown }
    override var keyCode: UInt16 { code }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var characters: String? { text }
    override var charactersIgnoringModifiers: String? { text }
}

@main
struct ClipboardTests {
    static func main() {
        exit(run())
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }

        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        func clipboard(_ text: String) {
            pasteboard.clearContents()
            precondition(pasteboard.setString(text, forType: .string), "System pasteboard is unavailable")
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = MosttyTerminalView(frame: window.contentView!.bounds)
        window.contentView = view
        defer { view.shutdown() }
        // Force grid synchronization without running timers or the fake EOF callback.
        view.setFrameSize(NSSize(width: 410, height: 200))
        view.resyncSurface()
        let firstTab = clipboard_test_created_tab()

        let keypadCases: [(UInt16, String)] = [
            (82, "\u{1b}Op"), (83, "\u{1b}Oq"), (84, "\u{1b}Or"), (85, "\u{1b}Os"),
            (86, "\u{1b}Ot"), (87, "\u{1b}Ou"), (88, "\u{1b}Ov"), (89, "\u{1b}Ow"),
            (91, "\u{1b}Ox"), (92, "\u{1b}Oy"), (65, "\u{1b}On"), (67, "\u{1b}Oj"),
            (69, "\u{1b}Ok"), (75, "\u{1b}Oo"), (76, "\u{1b}OM"), (78, "\u{1b}Om"),
            (81, "\u{1b}OX"),
        ]
        for (keyCode, sequence) in keypadCases {
            expect(KeyInput.keypadBytes(keyCode, applicationMode: true) == Array(sequence.utf8),
                   "DECKPAM maps keypad keyCode \(keyCode) to its xterm application sequence")
            expect(KeyInput.keypadBytes(keyCode, applicationMode: false) == nil,
                   "normal keypad mode leaves keyCode \(keyCode) on the existing AppKit text path")
        }
        clipboard_test_keypad_mode(true)
        clipboard_test_reset(false)
        let keypadZero = KeypadEvent()
        keypadZero.code = 82
        keypadZero.text = "0"
        view.keyDown(with: keypadZero)
        var keypadOutput = [UInt8](repeating: 0, count: 16)
        let keypadCount = clipboard_test_written(&keypadOutput, keypadOutput.count)
        expect(clipboard_test_keypad_queries() == 1,
               "the macOS host queries terminal DECKPAM state for keypad input")
        expect(Array(keypadOutput.prefix(keypadCount)) == Array("\u{1b}Op".utf8),
               "the macOS host sends the application sequence selected by DECKPAM state")

        let start = "\u{1b}[200~", end = "\u{1b}[201~"
        let cases: [(String, String)] = [
            ("first\r\nsecond\nthird\rfourth", "first\rsecond\rthird\rfourth"),
            ("\r\n\n\r\r\n", "\r\r\r\r"),
            ("", ""),
            ("\u{4e2d}\u{1f642}e\u{301}\t", "\u{4e2d}\u{1f642}e\u{301}\t"),
            ("a\r\(end)\nb", "a\r\(end)\rb"),
        ]
        for bracketed in [false, true] {
            for (index, pair) in cases.enumerated() {
                clipboard_test_reset(bracketed)
                clipboard(pair.0)
                view.paste(nil)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let n = clipboard_test_written(&bytes, bytes.count)
                let expected = bracketed
                    ? start + pair.1.replacingOccurrences(of: end, with: "") + end
                    : pair.1
                expect(Array(bytes.prefix(n)) == Array(expected.utf8),
                       "paste case \(index), bracketed=\(bracketed): CRLF/LF become CR, preserving text and framing")
            }
        }

        func mouse(_ type: NSEvent.EventType, _ col: Int, clicks: Int = 1,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let cell = view.overlayCellPoints
            let point = view.convert(NSPoint(x: (Double(col) + 0.5) * cell.w,
                                             y: Double(view.bounds.height) - cell.h * 0.5), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                      timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 0))
        view.mouseDragged(with: mouse(.leftMouseDragged, 2))
        expect(pasteboard.string(forType: .string) == "sentinel", "dragging alone does not copy")
        view.mouseUp(with: mouse(.leftMouseUp, 4))
        expect(pasteboard.string(forType: .string) == "hello", "release automatically copies the final selection")
        clipboard("sentinel")
        view.copy(nil)
        expect(pasteboard.string(forType: .string) == "hello", "manual copy still works")
        expect(clipboard_test_selection_active(), "the copied selection stays highlighted after release")
        let typedKey = KeypadEvent()
        typedKey.code = 82
        typedKey.text = "0"
        view.keyDown(with: typedKey)
        expect(!clipboard_test_selection_active(),
               "input drops the highlight because it no longer marks what the clipboard holds")
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 0))
        view.mouseUp(with: mouse(.leftMouseUp, 0))
        expect(pasteboard.string(forType: .string) == "sentinel", "a click without selection preserves the clipboard")
        view.mouseUp(with: mouse(.leftMouseUp, 4))
        expect(pasteboard.string(forType: .string) == "sentinel", "an unmatched release preserves the clipboard")
        clipboard_test_reset(false)
        clipboard("right-paste")
        view.rightMouseDown(with: mouse(.rightMouseDown, 2))
        view.rightMouseUp(with: mouse(.rightMouseUp, 2))
        var rightBytes = [UInt8](repeating: 0, count: 64)
        let rightCount = clipboard_test_written(&rightBytes, rightBytes.count)
        expect(Array(rightBytes.prefix(rightCount)) == Array("right-paste".utf8),
               "the right press pastes like the Win32 host when the application is not reading the mouse")
        clipboard_test_mouse_mode(true)
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 2))
        expect(clipboard_test_mouse_count() == 1 && clipboard_test_mouse_action() == 0 &&
               clipboard_test_mouse_button() == 0, "mouse mode routes the left press to the application")
        expect(clipboard_test_mouse_x() == 25 && clipboard_test_mouse_y() == 10,
               "native point coordinates become top-left device pixels")
        view.mouseDragged(with: mouse(.leftMouseDragged, 4))
        expect(clipboard_test_mouse_action() == 2, "application drag emits motion")
        view.mouseUp(with: mouse(.leftMouseUp, 4))
        expect(clipboard_test_mouse_count() == 3 && clipboard_test_mouse_action() == 1,
               "application drag ends with one release")
        expect(clipboard_test_write_tab() == firstTab && pasteboard.string(forType: .string) == "sentinel",
               "application drag stays with its tab and cannot copy a host selection")
        view.mouseUp(with: mouse(.leftMouseUp, 4))
        expect(clipboard_test_mouse_count() == 3, "unmatched releases are not reported")
        view.mouseDown(with: mouse(.leftMouseDown, 0, flags: .shift))
        view.mouseDragged(with: mouse(.leftMouseDragged, 4, flags: .shift))
        view.mouseUp(with: mouse(.leftMouseUp, 4, flags: .shift))
        expect(clipboard_test_mouse_count() == 3 && pasteboard.string(forType: .string) == "hello",
               "Shift bypass preserves host selection while application mouse mode is enabled")
        view.rightMouseDown(with: mouse(.rightMouseDown, 2))
        view.rightMouseUp(with: mouse(.rightMouseUp, 2))
        expect(clipboard_test_mouse_count() == 5 && clipboard_test_mouse_button() == 2,
               "right button routes press and release")
        view.mouseDown(with: mouse(.leftMouseDown, -1))
        view.mouseUp(with: mouse(.leftMouseUp, -1))
        expect(clipboard_test_mouse_count() == 5, "outside-grid clicks are not reported")
        let wheel = MouseWheelEvent()
        wheel.point = mouse(.mouseMoved, 2).locationInWindow
        wheel.delta = 1
        view.scrollWheel(with: wheel)
        expect(clipboard_test_mouse_count() == 6 && clipboard_test_mouse_button() == 3,
               "wheel up is routed to the terminal application")
        wheel.delta = 0
        wheel.horizontalDelta = -1
        view.scrollWheel(with: wheel)
        expect(clipboard_test_mouse_count() == 7 && clipboard_test_mouse_button() == 6,
               "horizontal wheel reports its direction")
        wheel.horizontalDelta = 0
        wheel.precise = true
        wheel.delta = view.overlayCellPoints.h / 2
        view.scrollWheel(with: wheel)
        expect(clipboard_test_mouse_count() == 7, "partial trackpad movement waits for a cell step")
        view.scrollWheel(with: wheel)
        expect(clipboard_test_mouse_count() == 8, "accumulated trackpad movement emits one wheel step")
        view.mouseDown(with: mouse(.leftMouseDown, 2))
        let capturedDrag = mouse(.leftMouseDragged, 4)
        let capturedRelease = mouse(.leftMouseUp, 4)
        let switched = MosttyTerminalView(frame: view.frame)
        window.contentView = switched
        // AppKit's local monitor must intercept events even with another tab attached.
        NSApp.sendEvent(capturedDrag)
        NSApp.sendEvent(capturedRelease)
        expect(clipboard_test_write_tab() == firstTab && clipboard_test_mouse_action() == 1 &&
               clipboard_test_mouse_count() == 11,
               "switching tabs mid-drag keeps motion and release on the originating PTY")
        switched.shutdown()
        window.contentView = view
        clipboard_test_mouse_mode(false)
        for (col, expected) in [(2, "hello"), (8, "x")] {
            clipboard("sentinel")
            view.mouseDown(with: mouse(.leftMouseDown, col, clicks: 2))
            expect(pasteboard.string(forType: .string) == "sentinel", "double-click waits for release to copy")
            view.mouseUp(with: mouse(.leftMouseUp, col, clicks: 2))
            expect(pasteboard.string(forType: .string) == expected,
                   "double-click release preserves the entire word, including a single-cell word")
            clipboard("sentinel")
            view.copy(nil)
            expect(pasteboard.string(forType: .string) == expected, "manual copy retains the selected word")
        }
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 2))
        view.mouseUp(with: mouse(.leftMouseUp, 2))
        expect(pasteboard.string(forType: .string) == "sentinel", "a new single click clears word selection")

        func openedURL() -> String? {
            clipboard_test_opened_url()
        }
        // Intercept only the platform browser dispatch; the production mouse handlers run unchanged.
        clipboard_test_url("https://example.test/a", true)
        defer { clipboard_test_restore_url_open() }
        view.updateTrackingAreas()
        expect(view.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.cursorUpdate) },
               "terminal registers mouse and cursor tracking")
        view.mouseMoved(with: mouse(.mouseMoved, 12))
        expect(clipboard_test_hovered_url(), "URL hover publishes the detected range to the renderer")
        expect(NSCursor.current == NSCursor.pointingHand, "URL hover sets the hand cursor")
        view.mouseMoved(with: mouse(.mouseMoved, -1))
        expect(!clipboard_test_hovered_url(), "outside-grid movement clears URL feedback")
        expect(NSCursor.current == NSCursor.arrow, "leaving URL restores the normal cursor")
        view.mouseMoved(with: mouse(.mouseMoved, 12))
        let leave = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 0, trackingNumber: 0, userData: nil)!
        view.mouseExited(with: leave)
        expect(!clipboard_test_hovered_url(), "mouse exit clears URL feedback")

        view.mouseMoved(with: mouse(.mouseMoved, 12))
        clipboard_test_url("http://changed.test/b", true)
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 12, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, 12, clicks: 2))
        expect(openedURL() == "http://changed.test/b", "double-click dispatches the current URL to the default browser API")
        expect(pasteboard.string(forType: .string) == "sentinel", "opening a URL does not copy a stale selection")

        clipboard_test_url("https://example.test/a", true)
        view.mouseDown(with: mouse(.leftMouseDown, 12, clicks: 2, flags: .shift))
        view.mouseUp(with: mouse(.leftMouseUp, 12, clicks: 2, flags: .shift))
        expect(openedURL() == nil, "Shift-double-click preserves URL text selection without opening")
        expect(pasteboard.string(forType: .string) == "hello", "Shift-double-click still copies the selected token")

        clipboard_test_url("https://example.test/a", false)
        clipboard("sentinel")
        view.mouseDown(with: mouse(.leftMouseDown, 12, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, 12, clicks: 2))
        expect(openedURL() == "https://example.test/a" && pasteboard.string(forType: .string) == "hello",
               "failed browser dispatch falls back to word selection")
        clipboard_test_url(nil, true)
        view.mouseMoved(with: mouse(.mouseMoved, 12))
        expect(!clipboard_test_hovered_url(), "changed viewport content invalidates a previous URL hit")
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        func fileDrag(_ paths: [String], operation: NSDragOperation = .copy) -> NSDraggingInfo {
            dragBoard.clearContents()
            precondition(dragBoard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }))
            return clipboard_test_drag(dragBoard, operation)
        }
        func writtenBytes() -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = clipboard_test_written(&bytes, bytes.count)
            return Array(bytes.prefix(count))
        }
        expect(view.registeredDraggedTypes.contains(.fileURL), "terminal registers native file drops")
        let ordinary = ["/Users/test/a b.txt", "/Users/test/\u{6587}\u{6863}.txt"]
        for bracketed in [false, true] {
            for paths in [[ordinary[0]], ordinary] {
                let drag = fileDrag(paths)
                clipboard_test_reset(bracketed)
                expect(view.draggingEntered(drag) == .copy && view.draggingUpdated(drag) == .copy,
                       "file drag advertises copy while over a live terminal")
                expect(writtenBytes().isEmpty, "drag hover does not send input")
                expect(view.performDragOperation(drag), "file drop is accepted")
                let quoted = paths.map { "\"" + $0 + "\"" }.joined(separator: " ") + " "
                let expected = bracketed ? start + quoted + end : quoted
                expect(writtenBytes() == Array(expected.utf8), "dropped paths remain separately double-quoted with correct paste framing")
                expect(clipboard_test_write_tab() == firstTab, "file drop writes to its terminal tab")
            }
        }
        let specialPaths = ["/Users/test/dollar$HOME.txt", "/Users/test/quote\"and'back\\slash.txt",
                            "/Users/test/$(printf expanded)`printf changed`.txt", "/Users/test/hello!missing.txt"]
        clipboard_test_reset(false)
        expect(view.performDragOperation(fileDrag(specialPaths)), "paths containing shell metacharacters are accepted")
        let shellInput = String(decoding: writtenBytes(), as: UTF8.self)

        clipboard_test_reset(false)
        expect(view.draggingEntered(fileDrag(ordinary, operation: .move)).isEmpty,
               "file drag cannot move or delete source files")
        expect(!view.performDragOperation(fileDrag(ordinary, operation: .move)) && writtenBytes().isEmpty,
               "unsupported drag operation sends no input")
        dragBoard.clearContents()
        dragBoard.setString("ordinary text", forType: .string)
        let textDrag = clipboard_test_drag(dragBoard, .copy)
        expect(view.draggingEntered(textDrag).isEmpty && !view.performDragOperation(textDrag),
               "non-file drags are rejected")
        expect(writtenBytes().isEmpty, "rejected drags preserve terminal input")

        let otherView = MosttyTerminalView(frame: view.frame)
        window.contentView = otherView
        otherView.resyncSurface()
        let secondTab = clipboard_test_created_tab()
        clipboard_test_reset(false)
        let otherDrag = fileDrag([ordinary[0]])
        expect(firstTab != secondTab && otherView.performDragOperation(otherDrag) && clipboard_test_write_tab() == secondTab,
               "after switching tabs, the visible terminal receives the dropped paths")
        expect(!view.performDragOperation(otherDrag), "a detached terminal cannot accept a file drop")
        otherView.shutdown()
        window.contentView = view
        view.resyncSurface()
        clipboard_test_reset(false)
        expect(view.performDragOperation(otherDrag) && clipboard_test_write_tab() == firstTab,
               "switching back restores the original drop destination")

        clipboard_test_url("https://example.test/a", true)
        view.mouseMoved(with: mouse(.mouseMoved, 12))
        view.shutdown()
        expect(!clipboard_test_hovered_url() && NSCursor.current == NSCursor.arrow,
               "closing a hovered tab clears the URL feedback and hand cursor")
        clipboard_test_reset(false)
        expect(view.draggingEntered(otherDrag).isEmpty && !view.performDragOperation(otherDrag) && writtenBytes().isEmpty,
               "closed terminals reject file drops without sending input")

        for (shell, interactive) in [("/bin/bash", false), ("/bin/zsh", false),
                                     ("/bin/bash", true), ("/bin/zsh", true)] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            let command = "set -- " + shellInput + "; printf '%s\\0' \"$@\""
            let input = Pipe()
            if interactive {
                process.arguments = shell.hasSuffix("bash") ? ["--noprofile", "--norc", "-i"] : ["-d", "-f", "-i"]
                var environment = ProcessInfo.processInfo.environment
                environment["HISTFILE"] = "/dev/null"
                process.environment = environment
                process.standardInput = input
                process.standardError = FileHandle.nullDevice
            } else {
                process.arguments = ["-fc", command]
            }
            let output = Pipe()
            process.standardOutput = output
            do {
                try process.run()
                if interactive {
                    let enableHistory = shell.hasSuffix("bash") ? "set -H" : "setopt BANG_HIST"
                    input.fileHandleForWriting.write(Data((enableHistory + "\n" + command + "\nexit\n").utf8))
                    try input.fileHandleForWriting.close()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let arguments = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                expect(process.terminationStatus == 0 && arguments == specialPaths,
                       "\(shell), interactive=\(interactive): paths survive variable, command and history expansion")
            } catch {
                expect(false, "\(shell) path-boundary verification failed: \(error)")
            }
        }
        // Return before exiting so clipboard restoration and shutdown run on failure.
        if failures > 0 {
            print("\(failures) clipboard regression checks failed")
        }
        return failures == 0 ? 0 : 1
    }
}
