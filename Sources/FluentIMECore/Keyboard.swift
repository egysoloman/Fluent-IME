import AppKit

public enum RimeKey {
    public static let backspace: Int32 = 0xff08
    public static let tab: Int32 = 0xff09
    public static let enter: Int32 = 0xff0d
    public static let escape: Int32 = 0xff1b
    public static let home: Int32 = 0xff50
    public static let left: Int32 = 0xff51
    public static let up: Int32 = 0xff52
    public static let right: Int32 = 0xff53
    public static let down: Int32 = 0xff54
    public static let pageUp: Int32 = 0xff55
    public static let pageDown: Int32 = 0xff56
    public static let end: Int32 = 0xff57
    public static let delete: Int32 = 0xffff

    public static func translate(keyCode: UInt16, characters: String) -> Int32? {
        let special: [UInt16: Int32] = [51: backspace, 48: tab, 36: enter, 76: enter,
            53: escape, 115: home, 123: left, 126: up, 124: right, 125: down,
            116: pageUp, 121: pageDown, 119: end, 117: delete]
        if let key = special[keyCode] { return key }
        guard characters.unicodeScalars.count == 1, let value = characters.unicodeScalars.first?.value,
              (0x20...0x7e).contains(value) else { return nil }
        return Int32(value)
    }
}

/// Only a bare Shift press/release toggles language, never Shift+A or Cmd+Shift.
public struct ShiftTapTracker {
    private var pending = false
    public init() {}
    public mutating func cancel() { pending = false }
    public mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == 56 || keyCode == 60 else { pending = false; return false }
        let relevant = flags.intersection([.shift, .control, .option, .command, .capsLock])
        if relevant == [.shift] { pending = true; return false }
        let toggle = pending && relevant.isEmpty
        pending = false
        return toggle
    }
}

public enum PanelPlacement {
    /// AppKit screen coordinates, including screens with negative origins.
    /// Left-aligned to the caret, or centered on it for small accessories such as the mode indicator.
    public static func frame(size: NSSize, caret: NSRect, screen: NSRect, gap: CGFloat = 6, centered: Bool = false) -> NSRect {
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(centered ? caret.midX - width / 2 : caret.minX, screen.minX), screen.maxX - width)
        let below = caret.minY - height - gap
        let y = below >= screen.minY ? below : min(caret.maxY + gap, screen.maxY - height)
        return NSRect(x: x, y: max(y, screen.minY), width: width, height: height)
    }
}
