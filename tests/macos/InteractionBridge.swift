import AppKit
import ObjectiveC

private var confirmEnabled = true
private var acceptClose = false
private var alerts = 0
private var safeCloseDefault = false
private var activeTheme = "Dark"
private var configPath: String?
private var fullscreen = false

private let respondToAlert: @convention(c) (NSAlert, Selector) -> Int = { confirmation, _ in
    alerts += 1
    confirmation.layout()
    safeCloseDefault = confirmation.buttons.count == 2 &&
        confirmation.buttons[0].title == "Cancel" &&
        confirmation.buttons[1].title == "Close" &&
        confirmation.window.defaultButtonCell !== confirmation.buttons[1].cell &&
        confirmation.buttons[1].keyEquivalent != "\r"
    return (acceptClose ? NSApplication.ModalResponse.alertSecondButtonReturn : .alertFirstButtonReturn).rawValue
}
func interaction_test_confirmation(_ enabled: Bool, _ accept: Bool) {
    confirmEnabled = enabled
    acceptClose = accept
    alerts = 0
    safeCloseDefault = false
    let method = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal))!
    method_setImplementation(method, unsafeBitCast(respondToAlert, to: IMP.self))
}
func interaction_test_alerts() -> Int { alerts }
func interaction_test_safe_close_default() -> Bool { safeCloseDefault }
@_cdecl("mostty_config_confirm_close")
func stubConfirmClose() -> Bool { confirmEnabled }
@_cdecl("mostty_config_reload")
func stubConfigReload() -> Bool { true }
func interaction_test_config_path(_ path: String) { configPath = path }
@_cdecl("mostty_config_path")
func stubConfigPath(_ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    guard let path = configPath else { return 0 }
    let bytes = Array(path.utf8)
    guard bytes.count <= capacity else { return 0 }
    buffer?.update(from: bytes, count: bytes.count)
    return bytes.count
}
@_cdecl("mostty_config_background_blur")
func stubBackgroundBlur() -> Bool { false }
@_cdecl("mostty_config_maximize")
func stubMaximize() -> Bool { false }
func interaction_test_fullscreen(_ enabled: Bool) { fullscreen = enabled }
@_cdecl("mostty_config_fullscreen")
func stubFullscreen() -> Bool { fullscreen }
@_cdecl("mostty_config_launcher_count")
func stubLauncherCount() -> Int { 2 }
private func text(_ value: String, _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    let bytes = Array(value.utf8)
    if capacity == 0 { return bytes.count }
    guard bytes.count <= capacity else { return 0 }
    buffer?.update(from: bytes, count: bytes.count)
    return bytes.count
}
@_cdecl("mostty_config_launcher_text")
func stubLauncherText(_ index: Int, _ field: UInt32, _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    let values = [["First", "echo first", "/usr"], ["Second", "echo second", "/var"]]
    return index >= 0 && index < 2 && field < 3 ? text(values[index][Int(field)], buffer, capacity) : 0
}
@_cdecl("mostty_config_refresh_themes")
func stubRefreshThemes() -> Int { 2 }
@_cdecl("mostty_config_theme_name")
func stubThemeName(_ index: Int, _ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int {
    index >= 0 && index < 2 ? text(index == 0 ? "Dark" : "Light", buffer, capacity) : 0
}
@_cdecl("mostty_config_active_theme")
func stubActiveTheme(_ buffer: UnsafeMutablePointer<UInt8>?, _ capacity: Int) -> Int { text(activeTheme, buffer, capacity) }
@_cdecl("mostty_config_select_theme")
func stubSelectTheme(_ name: UnsafePointer<CChar>?) -> Bool {
    guard let name else { return false }
    let theme = String(cString: name)
    guard theme == "Dark" || theme == "Light" else { return false }
    activeTheme = theme
    return true
}
