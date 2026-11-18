import Foundation

/// macOS 虚拟键码 → Rime 使用的 X11 keysym 和修饰键掩码。
/// 只做按键编码转换，不记录也不保存任何按键。
public enum RimeKeys {
    // Rime 修饰键掩码（与 rime_api.h / X11 一致）
    public static let shiftMask: Int32 = 1 << 0
    public static let lockMask: Int32 = 1 << 1
    public static let controlMask: Int32 = 1 << 2
    public static let altMask: Int32 = 1 << 3
    public static let superMask: Int32 = 1 << 26
    public static let releaseMask: Int32 = 1 << 30

    /// 修饰键本身（flagsChanged 事件的键码）
    public static let modifierKeysyms: [UInt16: Int32] = [
        56: 0xFFE1,   // Shift_L
        60: 0xFFE2,   // Shift_R
        59: 0xFFE3,   // Control_L
        62: 0xFFE4,   // Control_R
        58: 0xFFE9,   // Alt_L
        61: 0xFFEA,   // Alt_R
        55: 0xFFEB,   // Super_L
        54: 0xFFEC,   // Super_R
        57: 0xFFE5,   // Caps_Lock
    ]

    /// 不产生字符的按键
    public static let specialKeysyms: [UInt16: Int32] = [
        36: 0xFF0D,   // Return
        76: 0xFF8D,   // KP_Enter
        48: 0xFF09,   // Tab
        49: 0x0020,   // space
        51: 0xFF08,   // BackSpace
        117: 0xFFFF,  // Delete
        53: 0xFF1B,   // Escape
        123: 0xFF51,  // Left
        124: 0xFF53,  // Right
        125: 0xFF54,  // Down
        126: 0xFF52,  // Up
        115: 0xFF50,  // Home
        119: 0xFF57,  // End
        116: 0xFF55,  // Page_Up
        121: 0xFF56,  // Page_Down
        122: 0xFFBE, 120: 0xFFBF, 99: 0xFFC0, 118: 0xFFC1,     // F1–F4
        96: 0xFFC2, 97: 0xFFC3, 98: 0xFFC4, 100: 0xFFC5,       // F5–F8
        101: 0xFFC6, 109: 0xFFC7, 103: 0xFFC8, 111: 0xFFC9,    // F9–F12
    ]

    /// 普通按键：优先按键码查特殊键，否则用不含修饰键的字符（可打印 ASCII）
    public static func keysym(keyCode: UInt16, charactersIgnoringModifiers: String?) -> Int32? {
        if let special = specialKeysyms[keyCode] { return special }
        guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let value = scalar.value
        guard value >= 0x20, value <= 0x7E else { return nil }
        return Int32(value)
    }

    public struct Modifiers: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
        public static let capsLock = Modifiers(rawValue: 1 << 4)
    }

    public static func mask(_ modifiers: Modifiers, release: Bool = false) -> Int32 {
        var mask: Int32 = 0
        if modifiers.contains(.shift) { mask |= shiftMask }
        if modifiers.contains(.capsLock) { mask |= lockMask }
        if modifiers.contains(.control) { mask |= controlMask }
        if modifiers.contains(.option) { mask |= altMask }
        if modifiers.contains(.command) { mask |= superMask }
        if release { mask |= releaseMask }
        return mask
    }
}
