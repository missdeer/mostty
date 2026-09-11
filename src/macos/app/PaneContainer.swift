import AppKit

/// Applies shared layout snapshots to persistent native views. The Zig model
/// owns the tree, ratios, minimum constraints, focus and maximization.
final class PaneContainer: NSView {
    private weak var tab: TabItem?
    var backingScale: CGFloat = 2
    private var arranging = false
    private var drag: (id: UInt32, axis: UInt32, offset: CGFloat)?

    init(tab: TabItem) {
        self.tab = tab
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Terminal panes")
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window { backingScale = window.backingScaleFactor }
        else { drag = nil }
        arrange()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = window { backingScale = window.backingScaleFactor }
        arrange()
    }

    override func layout() {
        super.layout()
        arrange()
    }

    func arrange() {
        guard !arranging, let tab = tab else { return }
        arranging = true
        defer { arranging = false }
        let minimum = tab.panes.reduce(NSSize(width: 1, height: 1)) { result, pane in
            let size = pane.view.minimumPaneSize
            return NSSize(width: max(result.width, size.width + 4), height: max(result.height, size.height + 4))
        }
        guard mostty_layout_bounds(tab.layout,
            MosttyLayoutRect(x: 0, y: 0, width: bounds.width, height: bounds.height),
            MosttyLayoutSize(width: minimum.width, height: minimum.height), 5) else { return }
        var visible = [MosttyLayoutPane](repeating: MosttyLayoutPane(), count: tab.panes.count)
        let count = mostty_layout_panes(tab.layout, &visible, visible.count)
        let snapshot = visible.prefix(count)
        for pane in tab.panes {
            if let region = snapshot.first(where: { $0.id == pane.id }) {
                let r = region.rect
                // Round edges, not independent sizes, to keep backing pixels
                // aligned at fractional divider positions and Retina scales.
                let x = (r.x * backingScale).rounded() / backingScale
                let y = (r.y * backingScale).rounded() / backingScale
                let right = ((r.x + r.width) * backingScale).rounded() / backingScale
                let bottom = ((r.y + r.height) * backingScale).rounded() / backingScale
                pane.view.frame = NSRect(x: x + 2, y: y + 2,
                                         width: max(0, right - x - 4), height: max(0, bottom - y - 4))
                if pane.view.superview !== self { addSubview(pane.view) }
            } else {
                // Detaching suppresses rendering, not PTY output processing.
                pane.view.removeFromSuperview()
            }
            pane.view.resyncSurface(scale: backingScale)
        }
        if let window = window {
            let size = mostty_layout_minimum(tab.layout)
            let chrome = max(0, window.contentLayoutRect.height - bounds.height)
            window.contentMinSize = NSSize(width: max(480, ceil(size.width)), height: max(300, ceil(size.height + chrome)))
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tab = tab else { return }
        for pane in tab.panes where pane.view.superview === self {
            (tab.activePane === pane ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            let border = NSBezierPath(rect: pane.view.frame.insetBy(dx: -1, dy: -1))
            border.lineWidth = 1
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tab = tab else { return }
        let point = convert(event.locationInWindow, from: nil)
        var divider = MosttyLayoutDivider()
        guard mostty_layout_divider(tab.layout, point.x, point.y, &divider) else { return }
        drag = (divider.id, divider.axis, divider.axis == 0 ? point.x - divider.rect.x : point.y - divider.rect.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tab = tab, let drag = drag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if mostty_layout_drag(tab.layout, drag.id, (drag.axis == 0 ? point.x : point.y) - drag.offset) {
            arrange()
        }
    }

    override func mouseUp(with event: NSEvent) { drag = nil }
}
