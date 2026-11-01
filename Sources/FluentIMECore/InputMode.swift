import Foundation

public enum InputMode: String, CaseIterable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"

    public var isChinese: Bool { self != .english }
    public var title: String {
        switch self {
        case .simplifiedChinese: return L10n.generalSimplifiedChinese
        case .traditionalChinese: return L10n.generalTraditionalChinese
        case .english: return L10n.modeEnglish
        }
    }
    public var badge: String {
        switch self {
        case .simplifiedChinese: return L10n.modeBadgeSimplified
        case .traditionalChinese: return L10n.modeBadgeTraditional
        case .english: return "A"
        }
    }
    public static func normalized(_ modes: [InputMode]) -> [InputMode] {
        let result = allCases.filter { modes.contains($0) }
        return result.isEmpty ? [.simplifiedChinese] : result
    }
}
