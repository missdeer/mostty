import AppKit

// Mirrors the `Key` enum in terminal/key_encode.zig — values must stay in sync.
enum MosttyKey: UInt32 {
    case up = 0, down = 1, right = 2, left = 3
    case home = 4, end = 5, pageUp = 6, pageDown = 7
    case insert = 8, delete = 9, enter = 10, tab = 11, backspace = 12, escape = 13
    case f1 = 14, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

enum KeyInput {
    static let modShift: UInt32 = 1
    static let modAlt: UInt32 = 2
    static let modCtrl: UInt32 = 4

    static func isKeypad(_ keyCode: UInt16) -> Bool {
        keypadFinal(keyCode) != nil
    }

    /// Encode the VT application-keypad form. Returning nil in normal mode
    /// keeps the event on AppKit's existing text-input path.
    static func keypadBytes(_ keyCode: UInt16, applicationMode: Bool) -> [UInt8]? {
        guard applicationMode, let final = keypadFinal(keyCode) else { return nil }
        return [0x1b, 0x4f, final]
    }

    private static func keypadFinal(_ keyCode: UInt16) -> UInt8? {
        switch keyCode {
        case 82: return 0x70 // 0 => p
        case 83: return 0x71 // 1 => q
        case 84: return 0x72 // 2 => r
        case 85: return 0x73 // 3 => s
        case 86: return 0x74 // 4 => t
        case 87: return 0x75 // 5 => u
        case 88: return 0x76 // 6 => v
        case 89: return 0x77 // 7 => w
        case 91: return 0x78 // 8 => x
        case 92: return 0x79 // 9 => y
        case 65: return 0x6e // decimal => n
        case 67: return 0x6a // multiply => j
        case 69: return 0x6b // plus => k
        case 75: return 0x6f // divide => o
        case 76: return 0x4d // enter => M
        case 78: return 0x6d // minus => m
        case 81: return 0x58 // equals => X
        default: return nil
        }
    }

    /// Map a macOS virtual key code to a terminal special key, or nil for keys
    /// that carry text (and should flow through the input context / IME).
    static func specialKey(_ keyCode: UInt16) -> MosttyKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 115: return .home
        case 119: return .end
        case 116: return .pageUp
        case 121: return .pageDown
        case 117: return .delete
        case 36, 76: return .enter
        case 48: return .tab
        case 51: return .backspace
        case 53: return .escape
        case 122: return .f1
        case 120: return .f2
        case 99: return .f3
        case 118: return .f4
        case 96: return .f5
        case 97: return .f6
        case 98: return .f7
        case 100: return .f8
        case 101: return .f9
        case 109: return .f10
        case 103: return .f11
        case 111: return .f12
        default: return nil
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.shift) { m |= modShift }
        if flags.contains(.option) { m |= modAlt }
        if flags.contains(.control) { m |= modCtrl }
        return m
    }

    /// Bytes for a character key modified by Control and/or Option. Control maps
    /// ASCII 0x40..0x7f to their C0 control code; Option acts as Meta, prefixing
    /// ESC. Returns nil when the event carries no usable base character.
    static func controlMetaBytes(_ event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags
        let ctrl = flags.contains(.control)
        let meta = flags.contains(.option)
        guard ctrl || meta else { return nil }
        guard let base = event.charactersIgnoringModifiers,
              let scalar = base.unicodeScalars.first else { return nil }

        var out: [UInt8] = []
        if meta { out.append(0x1b) }

        if ctrl {
            let v = scalar.value
            if v == 0x20 || v == 0x32 { // Space or '2' => NUL
                out.append(0)
            } else if v >= 0x40 && v < 0x80 {
                out.append(UInt8(v & 0x1f))
            } else {
                return meta ? out : nil
            }
        } else {
            out.append(contentsOf: Array(base.utf8))
        }
        return out.isEmpty ? nil : out
    }

}
