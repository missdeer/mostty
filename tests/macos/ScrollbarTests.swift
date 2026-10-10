import AppKit
import QuartzCore

private final class ScrollWheelEvent: NSEvent {
    var point = NSPoint.zero
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { 3 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}

@main
struct ScrollbarTests {
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = MosttyTerminalView(frame: window.contentView!.bounds)
        window.contentView = view
        defer { view.shutdown() }
        window.makeKeyAndOrderFront(nil)
        view.setFrameSize(NSSize(width: 650, height: 400))
        view.resyncSurface()
        let tab = clipboard_test_created_tab()!
        let scroller = view.subviews.compactMap { $0 as? NSScroller }.first!
        let surface = view.subviews.first { $0.layer is CAMetalLayer }!
        var failures = 0
        func expect(_ condition: Bool, _ rule: String) {
            print("\(condition ? "PASS" : "FAIL"): \(rule)")
            if !condition { failures += 1 }
        }
        func refresh(_ total: UInt64, _ offset: UInt64, _ visible: UInt64) {
            clipboard_test_scrollback(tab, total, offset, visible)
            view.viewDidMoveToWindow()
        }
        func aligned() -> Bool {
            let layer = surface.layer as! CAMetalLayer
            return surface.frame.maxX == scroller.frame.minX &&
                scroller.frame.maxX == view.bounds.maxX &&
                layer.drawableSize.width == floor(surface.bounds.width * window.backingScaleFactor) &&
                layer.drawableSize.height == floor(surface.bounds.height * window.backingScaleFactor)
        }
        expect(!scroller.isHidden && !scroller.isEnabled && scroller.knobProportion == 1,
               "a terminal without history retains a visible, disabled scrollbar")
        expect(aligned(), "the native scrollbar reserves space outside the exact-size Metal surface")
        expect(view.hitTest(NSPoint(x: 20, y: 20)) === view,
               "the Metal child keeps terminal input on its owning view")
        expect(scroller.isFlipped && scroller.convert(.zero, to: view).y == view.bounds.maxY,
               "the native scroller's zero coordinate is physically at the terminal's top")
        mostty_tab_scroll_to_row(nil, 0)
        refresh(200, 90, 20)
        expect(scroller.isEnabled && abs(scroller.doubleValue - 0.5) < 0.001 &&
               abs(scroller.knobProportion - 0.1) < 0.001,
               "the knob represents the viewport's position and share of history")
        clipboard_test_mouse_mode(true)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: scroller.convert(point, to: nil), modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(to y: CGFloat) {
            let knob = scroller.rect(for: .knob)
            let start = NSPoint(x: knob.midX, y: knob.midY)
            let end = NSPoint(x: knob.midX, y: y)
            NSApp.postEvent(event(.leftMouseDragged, end), atStart: false)
            NSApp.postEvent(event(.leftMouseUp, end), atStart: false)
            // Native tracking also consults NSApp.currentEvent. Dispatch the
            // press through AppKit, as a real window event would arrive.
            NSApp.sendEvent(event(.leftMouseDown, start))
            print("DRAG: target=\(y) value=\(scroller.doubleValue) row=\(mostty_tab_scrollbar(tab).offset)")
        }
        let knobPoint = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: view)
        expect(view.hitTest(knobPoint) === scroller, "native scrollbar hit testing isolates terminal mouse reporting")
        drag(to: scroller.bounds.minY - 100)
        expect(mostty_tab_scrollbar(tab).offset == 0 && scroller.doubleValue == 0,
               "dragging beyond the top clamps to the first history row")
        expect(scroller.convert(scroller.rect(for: .knob), to: view).midY > view.bounds.midY,
               "the oldest viewport places the knob physically above the midpoint")
        drag(to: scroller.bounds.maxY + 100)
        expect(mostty_tab_scrollbar(tab).offset == 180 && scroller.doubleValue == 1,
               "dragging beyond the bottom clamps to the active viewport")
        expect(scroller.convert(scroller.rect(for: .knob), to: view).midY < view.bounds.midY,
               "the active viewport places the knob physically below the midpoint")
        drag(to: scroller.bounds.midY)
        let middle = mostty_tab_scrollbar(tab).offset
        expect(middle > 0 && middle < 180 && abs(scroller.doubleValue - Double(middle) / 180) < 0.001,
               "native knob dragging stays synchronized with the resulting middle viewport")
        let slot = scroller.rect(for: .knobSlot)
        let trackPoint = NSPoint(x: slot.midX, y: (slot.minY + scroller.rect(for: .knob).minY) / 2)
        NSApp.postEvent(event(.leftMouseUp, trackPoint), atStart: false)
        NSApp.sendEvent(event(.leftMouseDown, trackPoint))
        expect(mostty_tab_scrollbar(tab).offset < middle, "clicking above the knob moves toward older history")
        refresh(200, 90, 20)
        let wheel = ScrollWheelEvent()
        wheel.point = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        scroller.scrollWheel(with: wheel)
        expect(mostty_tab_scrollbar(tab).offset == 87,
               "wheel events over the scrollbar scroll history even with terminal mouse mode enabled")
        expect(clipboard_test_mouse_count() == 0, "scrollbar drags, track clicks and wheel events emit no PTY mouse reports")
        view.setFrameSize(NSSize(width: 800, height: 450))
        view.resyncSurface()
        expect(aligned(), "resizing keeps the drawable and reserved scrollbar strip aligned")
        let other = MosttyTerminalView(frame: view.frame)
        window.contentView = other
        let otherScroller = other.subviews.compactMap { $0 as? NSScroller }.first!
        expect(!otherScroller.isEnabled, "a new tab does not inherit another tab's history indicator")
        window.contentView = view
        expect(scroller.isEnabled && mostty_tab_scrollbar(tab).offset == 87,
               "switching back restores the original tab's scroll position")
        other.shutdown()
        refresh(20, 0, 20)
        expect(!scroller.isEnabled && scroller.knobProportion == 1,
               "switching to a screen without history disables the existing control")
        if failures > 0 { exit(1) }
    }
}
