import AppKit
import Metal
import QuartzCore

struct TerminalLauncher {
    let label: String
    let command: String
    let directory: String
}

/// One terminal surface: owns a bridge tab (PTY + renderer), presents frames
/// through a CAMetalLayer, and captures keyboard / mouse / IME input. All bridge
/// calls except the background reader happen on the main thread.
final class MosttyTerminalView: NSView, NSTextInputClient {
    private var tab: OpaquePointer?
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?
    private var device: MTLDevice?

    private var alive = false
    private var terminated = false
    private var dirty = false

    private var cols: UInt32 = 0
    private var rows: UInt32 = 0
    private var cellWidthPx: UInt32 = 1
    private var cellHeightPx: UInt32 = 1
    private var lastPixelW: UInt32 = 0
    private var lastPixelH: UInt32 = 0
    private var surfaceScale: CGFloat = 2
    private var lastScale: CGFloat = 0
    private var closed = false

    // Config-derived state the host owns. Fonts and colors live inside the
    // bridge; these two shape AppKit-side behaviour instead.
    private var backgroundOpacity = mostty_config_background_opacity()
    private var renderIntervalMs = max(UInt32(1), mostty_config_render_interval_ms())
    private var translucent: Bool { backgroundOpacity < 1 }

    private var renderTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var readerThread: Thread?
    private let readerDone = DispatchSemaphore(value: 0)
    // Caps how many PTY chunks may be queued on the main thread at once, so
    // sustained high-throughput output can't grow memory without bound.
    private let feedInFlight = DispatchSemaphore(value: 8)
    private let stopLock = NSLock()
    private var stopFlag = false

    // Selection (grid coords, viewport space) and IME composition state.
    private var selStart = (col: 0, row: 0)
    private var selEnd = (col: 0, row: 0)
    private var selecting = false
    private var selectingWord = false
    private var hasSelection = false
    private var urlTrackingArea: NSTrackingArea?
    private var hoveringURL = false
    private var scrollAccum = 0.0
    private var horizontalScrollAccum = 0.0
    private var scrollReporting = false
    private var reportingButtons = Set<UInt32>()
    private var mouseMonitor: Any?
    private weak var mouseWindow: NSWindow?
    private var mouseOrigin = NSPoint.zero
    private var mouseScale = 1.0
    private var markedText = ""

    private let surface = TerminalMetalView(frame: .zero)
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
    private var overlay: OverlayView?

    var onTitleChange: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onFocus: (() -> Void)?
#if MOSTTY_APP_TESTS
    var testSession: OpaquePointer? { tab }
#endif
    var launcher: TerminalLauncher?
    var hasActiveSession: Bool {
        guard alive, !terminated, let tab = tab else { return false }
        var code: Int32 = 0
        return !mostty_tab_poll_exit(tab, &code)
    }
    var minimumPaneSize: NSSize {
        NSSize(width: max(8, CGFloat(cellWidthPx) / surfaceScale) * 12 +
               NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy),
               height: max(16, CGFloat(cellHeightPx) / surfaceScale) * 3)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        surface.wantsLayer = true
        addSubview(surface)
        let ov = OverlayView(frame: bounds)
        ov.owner = self
        ov.autoresizingMask = [.width, .height]
        addSubview(ov)
        overlay = ov
        scroller.scrollerStyle = .legacy
        scroller.controlSize = .regular
        scroller.target = self
        scroller.action = #selector(scrollbarChanged(_:))
        scroller.isContinuous = true
        scroller.setAccessibilityLabel("Terminal scrollback")
        addSubview(scroller)
        layoutSurface()
        updateScroller()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var isOpaque: Bool { !translucent }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        onFocus?()
        dirty = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        commitMarkedIfNeeded()
        dirty = true
        return true
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            surfaceScale = window.backingScaleFactor
            window.acceptsMouseMovedEvents = true
            setupIfNeeded()
            updateScroller()
        } else {
            updateURLHover(at: nil)
        }
    }

    override func layout() {
        super.layout()
        layoutSurface()
        setupIfNeeded()
    }

    private func layoutSurface() {
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let contentWidth = max(0, bounds.width - width)
        surface.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        overlay?.frame = surface.frame
        scroller.frame = NSRect(x: contentWidth, y: 0, width: width, height: bounds.height)
    }

    private func currentScale() -> CGFloat { window?.backingScaleFactor ?? surfaceScale }

    private func pixelSize() -> (w: UInt32, h: UInt32) {
        let scale = currentScale()
        let w = UInt32(max(1.0, Double(surface.bounds.width) * Double(scale)))
        let h = UInt32(max(1.0, Double(bounds.height) * Double(scale)))
        return (w, h)
    }

    private func setupIfNeeded() {
        guard !closed, tab == nil, window != nil, bounds.width > 1, bounds.height > 1 else { return }
        layoutSurface()
        let scale = currentScale()
        let (pw, ph) = pixelSize()
        let created: OpaquePointer?
        if let launcher = launcher {
            created = mostty_tab_create_with_launcher(pw, ph, Float(scale), launcher.command, launcher.directory)
        } else {
            created = mostty_tab_create(pw, ph, Float(scale))
        }
        guard let t = created else { return }
        tab = t

        guard let devPtr = mostty_tab_metal_device(t),
              let dev = Unmanaged<AnyObject>.fromOpaque(devPtr).takeUnretainedValue() as? MTLDevice,
              let layer = surface.layer as? CAMetalLayer else {
            mostty_tab_destroy(t); tab = nil; return
        }
        device = dev
        layer.device = dev
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: Int(pw), height: Int(ph))
        layer.isOpaque = !translucent
        metalLayer = layer
        commandQueue = dev.makeCommandQueue()

        var cw: UInt32 = 1, ch: UInt32 = 1
        mostty_tab_cell_size(t, &cw, &ch)
        cellWidthPx = max(1, cw); cellHeightPx = max(1, ch)
        lastPixelW = pw; lastPixelH = ph
        lastScale = scale

        alive = true
        dirty = true
        startReader(t)
        startTimer()
        startBlink()
        updateTitle()
    }

    func shutdown() {
        closed = true
        endMouseCapture()
        updateURLHover(at: nil)
        guard alive else {
            if let t = tab { mostty_tab_destroy(t); tab = nil }
            return
        }
        alive = false
        setStop(true)
        if readerThread != nil { readerDone.wait() }
        renderTimer?.invalidate(); renderTimer = nil
        blinkTimer?.invalidate(); blinkTimer = nil
        if let t = tab { mostty_tab_destroy(t); tab = nil }
    }

    deinit { shutdown() }

    // MARK: Reader thread

    private func setStop(_ v: Bool) { stopLock.lock(); stopFlag = v; stopLock.unlock() }
    private func getStop() -> Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopFlag }

    private func startReader(_ t: OpaquePointer) {
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let cap = 1 << 16
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { buf.deallocate(); self.readerDone.signal() }
            while !self.getStop() {
                let n = mostty_tab_read(t, buf, cap)
                if n == -2 { continue }
                if n <= 0 {
                    DispatchQueue.main.async { self.handleEOF() }
                    break
                }
                let bytes = Array(UnsafeBufferPointer(start: buf, count: Int(n)))
                // Block until a feed slot frees up, re-checking the stop flag so
                // shutdown can't wedge the reader behind a main thread that has
                // stopped draining the queue.
                var acquired = false
                while !acquired {
                    if self.getStop() { break }
                    acquired = self.feedInFlight.wait(timeout: .now() + 0.1) == .success
                }
                if !acquired { break }
                DispatchQueue.main.async {
                    defer { self.feedInFlight.signal() }
                    guard self.alive, let tab = self.tab else { return }
                    bytes.withUnsafeBufferPointer { p in
                        mostty_tab_feed(tab, p.baseAddress, bytes.count)
                    }
                    self.dirty = true
                    self.updateTitle()
                }
            }
        }
        thread.stackSize = 1 << 20
        readerThread = thread
        thread.start()
    }

    private func handleEOF() {
        guard alive, let t = tab, !terminated else { return }
        var code: Int32 = 0
        _ = mostty_tab_poll_exit(t, &code)
        terminated = true
        dirty = true
        onExit?()
    }

    // MARK: Rendering

    private func startTimer() {
        let timer = Timer(timeInterval: Double(renderIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
            self?.renderTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    /// Adopt a reloaded config. Fonts and colors are re-applied inside the
    /// bridge; the layer's opacity and the frame cadence are host-owned.
    func applyConfig() {
        backgroundOpacity = mostty_config_background_opacity()
        metalLayer?.isOpaque = !translucent

        // Record the interval even for a tab that has not started yet, so it
        // opens at the configured cadence instead of the one loaded at launch.
        let interval = max(UInt32(1), mostty_config_render_interval_ms())
        if interval != renderIntervalMs {
            renderIntervalMs = interval
            if renderTimer != nil {
                renderTimer?.invalidate()
                startTimer()
            }
        }

        if let t = tab, mostty_tab_apply_config(t) {
            // Font reload must refresh each session, including hidden panes.
            lastPixelW = 0
            lastPixelH = 0
        }
        resyncSurface()
        dirty = true
        needsDisplay = true
    }

    /// Hidden panes retain their last host scale and independent geometry.
    func resyncSurface(scale: CGFloat? = nil) {
        if let scale = scale { surfaceScale = scale }
        setupIfNeeded()
        syncSurfaceIfNeeded()
        updateScroller()
    }

    private func startBlink() {
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // The cursor and SGR blinking text both need a frame on each toggle.
            self.blinkOn.toggle()
            self.dirty = true
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    private func renderTick() {
        // Background tabs are detached from the window; skip rendering entirely
        // so they don't rasterize at 60 Hz (the blink timer keeps dirty set, and
        // an offscreen layer's nextDrawable can be nil, re-arming dirty forever).
        // The reader still feeds VT state; the next present happens when shown.
        guard window != nil else { return }
        syncSurfaceIfNeeded()
        updateScroller()
        guard alive, dirty, let t = tab, let layer = metalLayer, let queue = commandQueue else { return }
        let mouse = window?.isKeyWindow == true
            ? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } : nil
        updateURLHover(at: mouse)
        dirty = false
        // Only the focused pane draws a blinking cursor.
        let focused = window?.firstResponder === self
        let cursorOn = focused && blinkOn
        var c: UInt32 = 0, r: UInt32 = 0
        guard let texPtr = mostty_tab_render(t, cursorOn, blinkOn, &c, &r) else { return }
        cols = c; rows = r
        guard let src = Unmanaged<AnyObject>.fromOpaque(texPtr).takeUnretainedValue() as? MTLTexture else { return }
        guard let drawable = layer.nextDrawable() else { dirty = true; return }
        let dst = drawable.texture
        guard src.width == dst.width, src.height == dst.height else { dirty = true; return }
        guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                  to: dst, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        overlay?.needsDisplay = true
    }

    private func syncSurfaceIfNeeded() {
        layoutSurface()
        guard alive, let t = tab, let layer = metalLayer else { return }
        let scale = currentScale()
        let (pw, ph) = pixelSize()
        if pw == lastPixelW && ph == lastPixelH && scale == lastScale { return }
        var nc: UInt32 = 0, nr: UInt32 = 0
        guard mostty_tab_set_surface(t, pw, ph, Float(scale), &nc, &nr) else { return }
        cols = nc; rows = nr
        var cw: UInt32 = 1, ch: UInt32 = 1
        mostty_tab_cell_size(t, &cw, &ch)
        cellWidthPx = max(1, cw); cellHeightPx = max(1, ch)
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: Int(pw), height: Int(ph))
        lastPixelW = pw; lastPixelH = ph
        lastScale = scale
        // Composition is anchored to the cursor; a resize commits it to avoid a
        // dangling overlay.
        commitMarkedIfNeeded()
        dirty = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        surfaceScale = currentScale()
        resyncSurface()
        dirty = true
    }

    private func updateTitle() {
        guard let t = tab else { return }
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = mostty_tab_title(t, &buf, buf.count)
        if n > 0 {
            let title = String(decoding: buf[0..<n], as: UTF8.self)
            onTitleChange?(title)
        }
    }

    // MARK: Writing

    private func writeBytes(_ bytes: [UInt8]) {
        guard let t = tab, !terminated, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { p in mostty_tab_write(t, p.baseAddress, bytes.count) }
    }

    private func writeString(_ s: String) { writeBytes(Array(s.utf8)) }

    private func scrollToBottomOnInput() {
        guard let t = tab else { return }
        mostty_tab_scroll_to_bottom(t)
        updateScroller()
        blinkOn = true
        dirty = true
    }

    private func updateScroller() {
        let state = mostty_tab_scrollbar(tab)
        let scrollable = state.total > state.visible
        scroller.isEnabled = scrollable
        scroller.knobProportion = state.total > 0 ? Double(state.visible) / Double(state.total) : 1
        scroller.doubleValue = scrollable ? Double(state.offset) / Double(state.total - state.visible) : 1
    }

    @objc private func scrollbarChanged(_ sender: NSScroller) {
        guard let t = tab else { return }
        let state = mostty_tab_scrollbar(t)
        guard state.total > state.visible else { return }
        let page = Int32(clamping: max(1, state.visible - 1))
        switch sender.hitPart {
        case .decrementLine: mostty_tab_scroll(t, -1)
        case .incrementLine: mostty_tab_scroll(t, 1)
        case .decrementPage: mostty_tab_scroll(t, -page)
        case .incrementPage: mostty_tab_scroll(t, page)
        case .knob, .knobSlot:
            let row = UInt64((sender.doubleValue * Double(state.total - state.visible)).rounded())
            mostty_tab_scroll_to_row(t, row)
        default: return
        }
        dirty = true
        updateScroller()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let t = tab, !terminated else { return }
        if !markedText.isEmpty {
            inputContext?.handleEvent(event)
            return
        }
        let flags = event.modifierFlags
        if flags.contains(.command) { super.keyDown(with: event); return }
        if KeyInput.isKeypad(event.keyCode),
           let bytes = KeyInput.keypadBytes(event.keyCode, applicationMode: mostty_tab_app_keypad(t)) {
            writeBytes(bytes)
            scrollToBottomOnInput()
            return
        }
        if let key = KeyInput.specialKey(event.keyCode) {
            sendKey(key, flags: flags)
            scrollToBottomOnInput()
            return
        }
        if flags.contains(.control) || flags.contains(.option) {
            if let bytes = KeyInput.controlMetaBytes(event) {
                writeBytes(bytes); scrollToBottomOnInput(); return
            }
        }
        if !(inputContext?.handleEvent(event) ?? false) {
            if let s = event.characters, !s.isEmpty { writeString(s); scrollToBottomOnInput() }
        }
    }

    private func sendKey(_ key: MosttyKey, flags: NSEvent.ModifierFlags) {
        guard let t = tab else { return }
        let app = mostty_tab_app_cursor_keys(t)
        var buf = [UInt8](repeating: 0, count: 16)
        let n = mostty_encode_key(key.rawValue, KeyInput.modifiers(flags), app, &buf, buf.count)
        if n > 0 { writeBytes(Array(buf[0..<n])) }
    }

    // MARK: Mouse

    private func gridCell(at p: NSPoint) -> (col: Int, row: Int) {
        let scale = Double(currentScale())
        let cwPts = Double(cellWidthPx) / scale
        let chPts = Double(cellHeightPx) / scale
        let col = cwPts > 0 ? Int(floor(Double(p.x) / cwPts)) : 0
        // Rows are laid out downward from the top edge, and the renderer keeps a
        // gutter at the bottom, so the row must be measured from the top rather
        // than inferred from the row count.
        let rowFromTop = chPts > 0 ? Int(floor((Double(bounds.height) - Double(p.y)) / chPts)) : 0
        return (col, rowFromTop)
    }

    private func cellAt(_ event: NSEvent) -> (col: Int, row: Int) {
        let cell = gridCell(at: convert(event.locationInWindow, from: nil))
        let clampedCol = min(max(0, cell.col), max(0, Int(cols) - 1))
        let clampedRow = min(max(0, cell.row), max(0, Int(rows) - 1))
        return (clampedCol, clampedRow)
    }

    private func viewportCell(at point: NSPoint) -> (col: UInt32, row: UInt32)? {
        guard surface.frame.contains(point) else { return nil }
        let cell = gridCell(at: point)
        guard cell.col >= 0, cell.row >= 0, cell.col < Int(cols), cell.row < Int(rows) else { return nil }
        return (UInt32(cell.col), UInt32(cell.row))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = urlTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        urlTrackingArea = area
    }

    private func updateURLHover(at point: NSPoint?) {
        guard let t = tab else { return }
        let cell = selecting || mostty_tab_mouse_enabled(t) ? nil : point.flatMap { viewportCell(at: $0) }
        let hit = mostty_tab_hover_url(t, cell != nil, cell?.col ?? 0, cell?.row ?? 0)
        if hit != hoveringURL { dirty = true }
        if let point = point { cursor(hoveringURL: hit, at: point).set() }
        hoveringURL = hit
    }

    /// The divider band overlaps the pane edges, so this view keeps receiving
    /// mouse-moved events there and must agree with PaneContainer instead of
    /// resetting the cursor behind its back. Set on every move, not just on
    /// hover transitions, so leaving the band always restores the cursor.
    private func cursor(hoveringURL hit: Bool, at point: NSPoint) -> NSCursor {
        if let container = superview as? PaneContainer,
           let divider = container.divider(at: convert(point, to: container)) {
            return PaneContainer.cursor(for: divider)
        }
        return hit ? .pointingHand : .arrow
    }

    override func mouseMoved(with event: NSEvent) {
        if !selecting, wantsMouseReport(event) { reportMouse(event, action: 2, button: 7) }
        updateURLHover(at: convert(event.locationInWindow, from: nil))
        dirty = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updateURLHover(at: nil) }

    private func openURL(at point: NSPoint) -> Bool {
        guard let t = tab, let cell = viewportCell(at: point) else { return false }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = mostty_tab_url_at(t, cell.col, cell.row, &buf, buf.count)
        guard n > 0, let url = URL(string: String(decoding: buf[0..<n], as: UTF8.self)) else { return false }
        return NSWorkspace.shared.open(url)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let t = tab else { return }
        if beginMouseReport(event, button: 0) { return }
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, !event.modifierFlags.contains(.shift), openURL(at: point) {
            selecting = false; selectingWord = false; hasSelection = false
            publishSelection()
            updateURLHover(at: point)
            return
        }
        let cell = cellAt(event)
        selStart = cell; selEnd = cell
        selecting = true; hasSelection = false
        updateURLHover(at: nil)
        selectingWord = event.clickCount == 2
        if selectingWord {
            hasSelection = mostty_tab_select_word(t, UInt32(cell.col), UInt32(cell.row))
            dirty = true
            return
        }
        publishSelection()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportingButtons.contains(0) { reportMouse(event, action: 2, button: 0); return }
        guard selecting else { return }
        selectingWord = false
        selEnd = cellAt(event)
        hasSelection = selStart != selEnd
        publishSelection()
    }

    override func mouseUp(with event: NSEvent) {
        if finishMouseReport(event, button: 0) { return }
        guard selecting else { return }
        selecting = false
        if !selectingWord {
            selEnd = cellAt(event)
            hasSelection = selStart != selEnd
            publishSelection()
        }
        selectingWord = false
        copy(nil)
    }

    private func wantsMouseReport(_ event: NSEvent) -> Bool {
        guard let t = tab, alive, !terminated else { return false }
        if !reportingButtons.isEmpty { return true }
        return !event.modifierFlags.contains(.shift) && mostty_tab_mouse_enabled(t) &&
            viewportCell(at: convert(event.locationInWindow, from: nil)) != nil
    }

    private func reportMouse(_ event: NSEvent, action: UInt32, button: UInt32) {
        guard let t = tab, alive, !terminated else { return }
        let captured = !reportingButtons.isEmpty
        let point = captured
            ? NSPoint(x: event.locationInWindow.x - mouseOrigin.x, y: event.locationInWindow.y - mouseOrigin.y)
            : convert(event.locationInWindow, from: nil)
        let scale = captured ? mouseScale : Double(currentScale())
        let x = Int32(clamping: Int(floor(Double(point.x) * scale)))
        let y = Int32(clamping: Int(floor((Double(bounds.height) - Double(point.y)) * scale)))
        mostty_tab_mouse(t, action, button, KeyInput.modifiers(event.modifierFlags), x, y)
    }

    private func beginMouseReport(_ event: NSEvent, button: UInt32) -> Bool {
        guard !selecting, wantsMouseReport(event) else { return false }
        if reportingButtons.isEmpty {
            mouseWindow = window
            mouseOrigin = convert(.zero, to: nil)
            mouseScale = Double(currentScale())
            // A tab switch detaches this view. Keep the originating view and
            // window coordinates as the report target until the buttons lift.
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel,
            ]) { [weak self] next in
                guard let self = self, !self.reportingButtons.isEmpty,
                      next.window === self.mouseWindow else { return next }
                if next.type == .scrollWheel { self.scrollWheel(with: next); return nil }
                let button: UInt32
                switch next.buttonNumber {
                case 0: button = 0
                case 1: button = 2
                case 2: button = 1
                default: return next
                }
                switch next.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    _ = self.beginMouseReport(next, button: button)
                case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                    _ = self.finishMouseReport(next, button: button)
                default:
                    if self.reportingButtons.contains(button) { self.reportMouse(next, action: 2, button: button) }
                }
                return nil
            }
        }
        reportingButtons.insert(button)
        reportMouse(event, action: 0, button: button)
        hasSelection = false
        publishSelection()
        updateURLHover(at: nil)
        return true
    }

    private func finishMouseReport(_ event: NSEvent, button: UInt32) -> Bool {
        guard reportingButtons.contains(button) else { return false }
        reportMouse(event, action: 1, button: button)
        reportingButtons.remove(button)
        if reportingButtons.isEmpty { endMouseCapture() }
        return true
    }

    private func endMouseCapture() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        mouseWindow = nil
        reportingButtons.removeAll()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !beginMouseReport(event, button: 2) { super.rightMouseDown(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) {
        if reportingButtons.contains(2) { reportMouse(event, action: 2, button: 2) }
    }
    override func rightMouseUp(with event: NSEvent) { _ = finishMouseReport(event, button: 2) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.buttonNumber == 2 { _ = beginMouseReport(event, button: 1) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2, reportingButtons.contains(1) { reportMouse(event, action: 2, button: 1) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { _ = finishMouseReport(event, button: 1) }
    }

    /// Hand the selection to the bridge so the highlight is painted with the
    /// configured `selection-background` / `selection-foreground` during
    /// rasterization. Drawing it in an overlay instead could only tint the
    /// finished pixels, which cannot honor a selection foreground color.
    private func publishSelection() {
        guard let t = tab else { return }
        mostty_tab_set_selection(t, hasSelection,
                                 UInt32(selStart.col), UInt32(selStart.row),
                                 UInt32(selEnd.col), UInt32(selEnd.row))
        dirty = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard let t = tab else { return }
        let reporting = !selecting && wantsMouseReport(event)
        if reporting != scrollReporting {
            scrollAccum = 0; horizontalScrollAccum = 0
            scrollReporting = reporting
        }
        scrollAccum += Double(event.scrollingDeltaY)
        // Precise (trackpad) deltas are points and must be divided by the cell
        // height; non-precise (mouse wheel) deltas are already line units.
        let step: Double
        if event.hasPreciseScrollingDeltas {
            let chPts = Double(cellHeightPx) / Double(currentScale())
            step = chPts > 0 ? chPts : 1
        } else {
            step = 1
        }
        let rowsMoved = Int(scrollAccum / step)
        if rowsMoved != 0 {
            scrollAccum -= Double(rowsMoved) * step
            if reporting {
                for _ in 0..<abs(rowsMoved) { reportMouse(event, action: 0, button: rowsMoved > 0 ? 3 : 4) }
            } else {
                mostty_tab_scroll(t, Int32(clamping: -rowsMoved))
                updateScroller()
            }
            dirty = true
        }
        if reporting {
            horizontalScrollAccum += Double(event.scrollingDeltaX)
            let xStep = event.hasPreciseScrollingDeltas ? max(1, Double(cellWidthPx) / Double(currentScale())) : 1
            let columnsMoved = Int(horizontalScrollAccum / xStep)
            horizontalScrollAccum -= Double(columnsMoved) * xStep
            for _ in 0..<abs(columnsMoved) { reportMouse(event, action: 0, button: columnsMoved > 0 ? 5 : 6) }
        }
    }

    // MARK: Copy / paste

    @objc func copy(_ sender: Any?) {
        guard hasSelection, let t = tab else { return }
        var probe: UInt8 = 0
        let size = mostty_tab_selection_text(t, &probe, 0)
        guard size > 0 else { return }
        var buf = [UInt8](repeating: 0, count: size)
        let n = mostty_tab_selection_text(t, &buf, buf.count)
        guard n > 0 else { return }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        pasteBytes(Array(s.utf8), normalizeNewlines: true)
    }

    private func pasteBytes(_ content: [UInt8], normalizeNewlines: Bool = false) {
        guard let t = tab, !terminated else { return }
        // Encoding can only shrink the content, plus two six-byte markers.
        var bytes = [UInt8](repeating: 0, count: content.count + 12)
        let n = mostty_encode_paste(content, content.count, mostty_tab_bracketed_paste(t),
                                    normalizeNewlines, &bytes, bytes.count)
        guard n > 0 else { return }
        bytes.removeSubrange(n..<bytes.count)
        writeBytes(bytes)
        scrollToBottomOnInput()
    }

    // MARK: File drops

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard alive, !terminated, window != nil, sender.draggingSourceOperationMask.contains(.copy),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedFileURLs(sender) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = droppedFileURLs(sender) else { return false }
        let paths = urls.map { url in
            // Escape double-quote metacharacters and isolate ! from interactive history expansion.
            let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
                                  .replacingOccurrences(of: "$", with: "\\$")
                                  .replacingOccurrences(of: "`", with: "\\`")
                                  .replacingOccurrences(of: "!", with: "\"'!'\"")
            return "\"" + escaped + "\""
        }
        pasteBytes(Array((paths.joined(separator: " ") + " ").utf8))
        window?.makeFirstResponder(self)
        return true
    }

    // MARK: NSTextInputClient

    private func commitMarkedIfNeeded() {
        if !markedText.isEmpty {
            writeString(markedText)
            markedText = ""
            // Tell the IME to drop its pending composition too; otherwise it
            // still believes marking is active and re-commits the same text
            // via insertText, duplicating it.
            inputContext?.discardMarkedText()
            overlay?.needsDisplay = true
        }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedText = ""
        writeString(s)
        scrollToBottomOnInput()
        overlay?.needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        // Composition anchors to the live cursor, which only has a viewport
        // position at the bottom; return there so the overlay isn't drawn over
        // scrollback when the user starts typing while scrolled up.
        scrollToBottomOnInput()
        overlay?.needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        overlay?.needsDisplay = true
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let t = tab else { return .zero }
        var col: UInt32 = 0, row: UInt32 = 0
        mostty_tab_cursor(t, &col, &row)
        let scale = Double(currentScale())
        let cwPts = Double(cellWidthPx) / scale
        let chPts = Double(cellHeightPx) / scale
        let x = Double(col) * cwPts
        let yFromTop = Double(row) * chPts
        let y = Double(bounds.height) - yFromTop - chPts
        let rect = NSRect(x: x, y: y, width: cwPts, height: chPts)
        let inWindow = convert(rect, to: nil)
        return window?.convertToScreen(inWindow) ?? rect
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    override func doCommand(by selector: Selector) {
        // Swallow default responder commands so unmapped keys don't beep; the
        // terminal encodes special keys itself in keyDown.
    }

    // Overlay accessors
    var overlayMarkedText: String { markedText }
    var overlayCellPoints: (w: Double, h: Double) {
        let scale = Double(currentScale())
        return (Double(cellWidthPx) / scale, Double(cellHeightPx) / scale)
    }
    func overlayCursor() -> (col: Int, row: Int) {
        guard let t = tab else { return (0, 0) }
        var col: UInt32 = 0, row: UInt32 = 0
        mostty_tab_cursor(t, &col, &row)
        return (Int(col), Int(row))
    }
}

private final class TerminalMetalView: NSView {
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Transparent layer above the Metal content that draws the IME composition text.
/// The selection highlight is not drawn here: it is applied during rasterization
/// so `selection-foreground` can recolor the glyphs themselves.
final class OverlayView: NSView {
    weak var owner: MosttyTerminalView?

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // pass events through

    override func draw(_ dirtyRect: NSRect) {
        guard let owner = owner else { return }
        let (cwp, chp) = owner.overlayCellPoints
        guard cwp > 0, chp > 0 else { return }

        let marked = owner.overlayMarkedText
        if !marked.isEmpty {
            let cursor = owner.overlayCursor()
            let x = Double(cursor.col) * cwp
            let yTop = Double(cursor.row) * chp
            let y = Double(bounds.height) - yTop - chp
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: chp * 0.7, weight: .regular),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor(calibratedWhite: 0.2, alpha: 0.9),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
            (marked as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
}
