import AppKit
import Metal
import ObjectiveC

// Replace only the C bridge: the tests run the production AppKit handlers.
private var written: [UInt8] = []
private let tabs = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
private var tabCount = 0
private var scrollbars = [MosttyScrollbar](repeating: MosttyScrollbar(), count: 8)
private var writeTab: OpaquePointer?
private var bracketedPaste = false
private var applicationKeypad = false
private var keypadQueries = 0
private var selectionActive = false
private var selectionEnd: UInt32 = 0
private var wordSelection = false
private var wordCol: UInt32 = 0
private var device: MTLDevice?
private var urlText: String?
private var openedURL: String?
private var hoveredURL = false
private var urlOpenSuccess = false
private var originalOpenURL: IMP?
private var mouseEnabled = false
private var mouseCount: UInt32 = 0
private var mouseAction: UInt32 = 0
private var mouseButton: UInt32 = 0
private var mouseX: Int32 = 0
private var mouseY: Int32 = 0

func clipboard_test_mouse_mode(_ enabled: Bool) { mouseEnabled = enabled; mouseCount = 0 }
func clipboard_test_mouse_count() -> UInt32 { mouseCount }
func clipboard_test_mouse_action() -> UInt32 { mouseAction }
func clipboard_test_mouse_button() -> UInt32 { mouseButton }
func clipboard_test_mouse_x() -> Int32 { mouseX }
func clipboard_test_mouse_y() -> Int32 { mouseY }

@_cdecl("mostty_tab_mouse_enabled")
func stubMouseEnabled(_ tab: OpaquePointer?) -> Bool { mouseEnabled }
@_cdecl("mostty_tab_mouse")
func stubMouse(_ tab: OpaquePointer?, _ action: UInt32, _ button: UInt32, _ mods: UInt32, _ x: Int32, _ y: Int32) {
    writeTab = tab
    mouseCount += 1; mouseAction = action; mouseButton = button; mouseX = x; mouseY = y
}

private let recordOpenURL: @convention(c) (AnyObject, Selector, NSURL) -> Bool = { _, _, url in
    openedURL = url.absoluteString
    return urlOpenSuccess
}
func clipboard_test_url(_ url: String?, _ openSuccess: Bool) {
    if originalOpenURL == nil {
        let method = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.open(_:)))!
        originalOpenURL = method_setImplementation(method, unsafeBitCast(recordOpenURL, to: IMP.self))
    }
    urlText = url
    openedURL = nil
    urlOpenSuccess = openSuccess
}
func clipboard_test_opened_url() -> String? { openedURL }
func clipboard_test_hovered_url() -> Bool { hoveredURL }
func clipboard_test_restore_url_open() {
    if let original = originalOpenURL {
        let method = class_getInstanceMethod(NSWorkspace.self, #selector(NSWorkspace.open(_:)))!
        method_setImplementation(method, original)
        originalOpenURL = nil
    }
}
func clipboard_test_reset(_ bracketed: Bool) { written.removeAll(); bracketedPaste = bracketed }
func clipboard_test_keypad_mode(_ enabled: Bool) { applicationKeypad = enabled; keypadQueries = 0 }
func clipboard_test_keypad_queries() -> Int { keypadQueries }
func clipboard_test_written(_ buffer: UnsafeMutablePointer<UInt8>, _ capacity: Int) -> Int {
    precondition(written.count <= capacity)
    buffer.update(from: written, count: written.count)
    return written.count
}

@_cdecl("mostty_tab_create")
func stubCreate(_ width: UInt32, _ height: UInt32, _ scale: Float) -> OpaquePointer? {
    precondition(tabCount < 8)
    scrollbars[tabCount] = MosttyScrollbar(total: UInt64(height / 20), offset: 0, visible: UInt64(height / 20))
    defer { tabCount += 1 }
    return OpaquePointer(tabs.advanced(by: tabCount))
}
@_cdecl("mostty_tab_create_with_launcher")
func stubCreateWithLauncher(_ width: UInt32, _ height: UInt32, _ scale: Float,
                           _ command: UnsafePointer<CChar>?, _ directory: UnsafePointer<CChar>?) -> OpaquePointer? {
    stubCreate(width, height, scale)
}
func clipboard_test_created_tab() -> OpaquePointer? { tabCount > 0 ? OpaquePointer(tabs.advanced(by: tabCount - 1)) : nil }
func clipboard_test_write_tab() -> OpaquePointer? { writeTab }
@_cdecl("mostty_tab_destroy")
func stubDestroy(_ tab: OpaquePointer?) {}
@_cdecl("mostty_config_background_opacity")
func stubBackgroundOpacity() -> Float { 1 }
@_cdecl("mostty_config_copy_tabbar_font")
func stubCopyTabbarFont() -> UnsafeMutableRawPointer? {
    Unmanaged.passRetained(NSFont(name: "Menlo", size: 13)!).toOpaque()
}
@_cdecl("mostty_config_render_interval_ms")
func stubRenderInterval() -> UInt32 { 16 }
@_cdecl("mostty_tab_apply_config")
func stubApplyConfig(_ tab: OpaquePointer?) -> Bool { false }
@_cdecl("mostty_tab_metal_device")
func stubMetalDevice(_ tab: OpaquePointer?) -> UnsafeMutableRawPointer? {
    if device == nil { device = MTLCreateSystemDefaultDevice() }
    return device.map { Unmanaged.passUnretained($0 as AnyObject).toOpaque() }
}
@_cdecl("mostty_tab_read")
func stubRead(_ tab: OpaquePointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    // A live idle session times out; EOF would asynchronously close its pane.
    usleep(10000)
    return -2
}
@_cdecl("mostty_tab_feed")
func stubFeed(_ tab: OpaquePointer?, _ pointer: UnsafePointer<UInt8>?, _ length: Int) {}
@_cdecl("mostty_tab_write")
func stubWrite(_ tab: OpaquePointer?, _ pointer: UnsafePointer<UInt8>?, _ length: Int) {
    writeTab = tab
    precondition(length <= 4096 - written.count)
    written.append(contentsOf: UnsafeBufferPointer(start: pointer, count: length))
}
@_cdecl("mostty_tab_set_surface")
func stubSetSurface(_ tab: OpaquePointer?, _ width: UInt32, _ height: UInt32, _ scale: Float,
                    _ cols: UnsafeMutablePointer<UInt32>?, _ rows: UnsafeMutablePointer<UInt32>?) -> Bool {
    cols?.pointee = width / 10; rows?.pointee = height / 20
    return true
}
@_cdecl("mostty_tab_render")
func stubRender(_ tab: OpaquePointer?, _ cursor: Bool, _ textBlinkOn: Bool,
                _ cols: UnsafeMutablePointer<UInt32>?, _ rows: UnsafeMutablePointer<UInt32>?) -> UnsafeMutableRawPointer? { nil }
@_cdecl("mostty_tab_title")
func stubTitle(_ tab: OpaquePointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int { 0 }
@_cdecl("mostty_tab_poll_exit")
func stubPollExit(_ tab: OpaquePointer?, _ code: UnsafeMutablePointer<Int32>?) -> Bool { false }
@_cdecl("mostty_tab_cell_size")
func stubCellSize(_ tab: OpaquePointer?, _ width: UnsafeMutablePointer<UInt32>?, _ height: UnsafeMutablePointer<UInt32>?) {
    width?.pointee = 10; height?.pointee = 20
}
@_cdecl("mostty_tab_cursor")
func stubCursor(_ tab: OpaquePointer?, _ col: UnsafeMutablePointer<UInt32>?, _ row: UnsafeMutablePointer<UInt32>?) {
    col?.pointee = 0; row?.pointee = 0
}
@_cdecl("mostty_tab_app_cursor_keys")
func stubAppCursorKeys(_ tab: OpaquePointer?) -> Bool { false }
@_cdecl("mostty_tab_app_keypad")
func stubAppKeypad(_ tab: OpaquePointer?) -> Bool { keypadQueries += 1; return applicationKeypad }
@_cdecl("mostty_tab_bracketed_paste")
func stubBracketedPaste(_ tab: OpaquePointer?) -> Bool { bracketedPaste }
@_cdecl("mostty_tab_scrollbar")
func stubScrollbar(_ tab: OpaquePointer?) -> MosttyScrollbar {
    guard let tab else { return MosttyScrollbar() }
    return scrollbars[tabs.distance(to: UnsafeMutablePointer<UInt8>(tab))]
}
func clipboard_test_scrollback(_ tab: OpaquePointer, _ total: UInt64, _ offset: UInt64, _ visible: UInt64) {
    scrollbars[tabs.distance(to: UnsafeMutablePointer<UInt8>(tab))] = MosttyScrollbar(total: total, offset: offset, visible: visible)
}
@_cdecl("mostty_tab_scroll_to_row")
func stubScrollToRow(_ tab: OpaquePointer?, _ row: UInt64) {
    guard let tab else { return }
    let index = tabs.distance(to: UnsafeMutablePointer<UInt8>(tab))
    let state = scrollbars[index]
    scrollbars[index].offset = min(row, state.total > state.visible ? state.total - state.visible : 0)
}
@_cdecl("mostty_tab_scroll")
func stubScroll(_ tab: OpaquePointer?, _ rows: Int32) {
    let state = stubScrollbar(tab)
    stubScrollToRow(tab, UInt64(max(0, Int64(state.offset) + Int64(rows))))
}
@_cdecl("mostty_tab_scroll_to_bottom")
func stubScrollToBottom(_ tab: OpaquePointer?) { stubScrollToRow(tab, UInt64.max) }
@_cdecl("mostty_tab_set_selection")
func stubSetSelection(_ tab: OpaquePointer?, _ active: Bool, _ sc: UInt32, _ sr: UInt32, _ ec: UInt32, _ er: UInt32) {
    selectionActive = active; selectionEnd = ec; wordSelection = false
}
@_cdecl("mostty_tab_select_word")
func stubSelectWord(_ tab: OpaquePointer?, _ col: UInt32, _ row: UInt32) -> Bool {
    selectionActive = true; wordSelection = true; wordCol = col
    return true
}
@_cdecl("mostty_tab_hover_url")
func stubHoverURL(_ tab: OpaquePointer?, _ active: Bool, _ col: UInt32, _ row: UInt32) -> Bool {
    hoveredURL = active && urlText != nil && col >= 10 && col < 30 && row == 0
    return hoveredURL
}
@_cdecl("mostty_tab_url_at")
func stubURLAt(_ tab: OpaquePointer?, _ col: UInt32, _ row: UInt32,
               _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    guard let text = urlText, col >= 10, col < 30, row == 0 else { return 0 }
    let bytes = Array(text.utf8)
    guard bytes.count <= capacity else { return 0 }
    buffer?.update(from: bytes, count: bytes.count)
    return bytes.count
}
@_cdecl("mostty_tab_selection_text")
func stubSelectionText(_ tab: OpaquePointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    precondition(selectionActive)
    let text = wordSelection ? (wordCol == 8 ? "x" : "hello") : (selectionEnd == 4 ? "hello" : "hel")
    let bytes = Array(text.utf8)
    if capacity == 0 { return bytes.count }
    precondition(bytes.count <= capacity)
    buffer?.update(from: bytes, count: bytes.count)
    return bytes.count
}

private final class ClipboardDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(_ pasteboard: NSPasteboard, _ operation: NSDragOperation) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = operation
        super.init()
    }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
func clipboard_test_drag(_ pasteboard: NSPasteboard, _ operation: NSDragOperation) -> NSDraggingInfo {
    ClipboardDragInfo(pasteboard, operation)
}
