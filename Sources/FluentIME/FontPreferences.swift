import AppKit
import FluentKit
import FluentIMECore

/// Font names refer only to families installed on this Mac. No fonts are bundled.
enum FontPreferences {
    static let system = "system"
    private static var available = Set(NSFontManager.shared.availableFontFamilies)
    static var signature: String { L10n.interfaceLanguage + "\u{0}" + InputMode.allCases.map { selected($0) }.joined(separator: "\u{0}") }
    static func selected(_ language: InputMode) -> String {
        let family = UserDefaults.standard.string(forKey: "fontFamily." + language.rawValue) ?? system
        return family == system || available.contains(family) ? family : system
    }
    static func set(_ family: String, for language: InputMode) {
        available = Set(NSFontManager.shared.availableFontFamilies)
        guard family == system || available.contains(family) else { return }
        UserDefaults.standard.set(family, forKey: "fontFamily." + language.rawValue)
        NotificationCenter.default.post(name: Preferences.changed, object: Preferences.shared)
    }
    static var choices: [(id: String, title: String)] {
        available = Set(NSFontManager.shared.availableFontFamilies)
        return [(system, L10n.fontSystem)] + available.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, $0) }
    }
    static var interfaceMode: InputMode { InputMode(rawValue: L10n.interfaceLanguage) ?? .simplifiedChinese }
    static func font(size: CGFloat, weight: NSFont.Weight, language: InputMode) -> NSFont {
        let family = selected(language)
        guard family != system, let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight >= .semibold ? 9 : 5, size: size) else { return .systemFont(ofSize: size, weight: weight) }
        return font
    }
}
