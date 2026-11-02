import AppKit

/// A user-recorded key combination. Matched by physical key code, so it keeps working
/// across keyboard layouts; `key` is only the label shown in settings.
public struct KeyShortcut: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var key: String
    public static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    public var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }

    public init(keyCode: UInt16, flags: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode; modifiers = flags.intersection(Self.relevant).rawValue; self.key = key.uppercased()
    }
    /// A key-down with its modifiers; nil for a bare modifier or an unlabelled key.
    public init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let label = Self.labels[event.keyCode] ?? event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, flags: event.modifierFlags, key: label)
    }
    public func matches(_ event: NSEvent) -> Bool {
        event.type == .keyDown && event.keyCode == keyCode && event.modifierFlags.intersection(Self.relevant) == flags
    }
    /// macOS order: ⌃⌥⇧⌘ then the key.
    public var display: String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { flags.contains($0.0) }.map(\.1).joined() + key
    }
    private static let labels: [UInt16: String] = [49: "Space", 48: "Tab", 36: "↩", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]

    public static let emojiDefault = KeyShortcut(keyCode: 14, flags: [.control, .option], key: "E")
    public static let clipboardDefault = KeyShortcut(keyCode: 9, flags: [.control, .option], key: "V")
}

public enum ShortcutConflict: Equatable {
    /// Without ⌃ or ⌘ the combination would be typed as text.
    case needsModifier
    /// ⌥ (with or without ⇧) types special characters on Mac keyboards.
    case typesCharacters
    /// A shortcut nearly every app uses, such as ⌘V.
    case common
    /// Taken by an enabled macOS keyboard shortcut.
    case system
    /// Already assigned to the other Fluent shortcut.
    case duplicate
}

public enum ShortcutValidator {
    /// ⌘ shortcuts for editing, files, windows and search, and the input source / emoji keys.
    private static let common: Set<String> = {
        var set = Set<String>()
        let command = NSEvent.ModifierFlags.command.rawValue
        for code: UInt16 in [0, 8, 9, 7, 6, 1, 12, 13, 45, 31, 35, 3, 17, 4, 46, 5, 32, 50, 48, 49] { set.insert("\(code):\(command)") }
        set.insert("6:\(NSEvent.ModifierFlags([.shift, .command]).rawValue)")       // ⇧⌘Z redo
        set.insert("49:\(NSEvent.ModifierFlags.control.rawValue)")                // ⌃Space input source
        set.insert("49:\(NSEvent.ModifierFlags([.control, .option]).rawValue)")  // ⌃⌥Space next source
        set.insert("49:\(NSEvent.ModifierFlags([.control, .command]).rawValue)") // ⌃⌘Space emoji viewer
        set.insert("3:\(NSEvent.ModifierFlags([.control, .command]).rawValue)")  // ⌃⌘F full screen
        set.insert("12:\(NSEvent.ModifierFlags([.control, .command]).rawValue)") // ⌃⌘Q lock screen
        return set
    }()

    public static func conflict(for shortcut: KeyShortcut, other: KeyShortcut?, system: [KeyShortcut]) -> ShortcutConflict? {
        let flags = shortcut.flags
        if flags.isDisjoint(with: [.control, .command]) { return flags.contains(.option) ? .typesCharacters : .needsModifier }
        if common.contains("\(shortcut.keyCode):\(flags.rawValue)") { return .common }
        if system.contains(where: { $0.keyCode == shortcut.keyCode && $0.flags == flags }) { return .system }
        if let other, other.keyCode == shortcut.keyCode, other.flags == flags { return .duplicate }
        return nil
    }

    /// Enabled shortcuts from System Settings → Keyboard → Keyboard Shortcuts.
    public static func systemShortcuts() -> [KeyShortcut] {
        guard let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return [] }
        return hotKeys.values.compactMap { entry in
            guard let entry = entry as? [String: Any], entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int], parameters.count == 3,
                  parameters[1] >= 0, parameters[1] < 0xFFFF else { return nil }
            return KeyShortcut(keyCode: UInt16(parameters[1]), flags: NSEvent.ModifierFlags(rawValue: UInt(parameters[2])), key: "")
        }
    }
}
