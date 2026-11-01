import Foundation

/// Interface language is independent of the selected pinyin schema and input mode.
/// SwiftPM owns this bundle; Bundle.main may be the IMK host or a test executable.
public enum L10n {
    static let supportedLanguages = ["zh-Hans", "zh-Hant", "en"]
    private static let resourceBundle = Bundle.module
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: supportedLanguages.compactMap { language in
        guard let path = resourceBundle.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else { return nil }
        return (language, bundle)
    })
    public static var interfaceLanguage: String {
        if let language = ProcessInfo.processInfo.environment["FLUENTIME_RENDER_LANGUAGE"] {
            return resolveLanguage([language])
        }
        if let chosen = UserDefaults.standard.string(forKey: "interfaceLanguage"), supportedLanguages.contains(chosen) { return chosen }
        return resolveLanguage(Locale.preferredLanguages)
    }
    public static var locale: Locale { Locale(identifier: interfaceLanguage) }

    static func resolveLanguage(_ preferences: [String]) -> String {
        for preference in preferences {
            let language = preference.replacingOccurrences(of: "_", with: "-").lowercased()
            if language == "en" || language.hasPrefix("en-") { return "en" }
            if language.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(language) { return "zh-Hant" }
            if language == "zh" || language.hasPrefix("zh-") { return "zh-Hans" }
        }
        return "zh-Hans"
    }

    private static func bundle(for language: String) -> Bundle? {
        bundles[language]
    }

    static func text(_ key: String, language: String? = nil) -> String {
        let fallback = bundle(for: "zh-Hans")?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        return bundle(for: language ?? interfaceLanguage)?.localizedString(forKey: key, value: fallback, table: "Localizable") ?? fallback
    }

    static func format(_ key: String, language: String? = nil, arguments: [CVarArg]) -> String {
        String(format: text(key, language: language), locale: Locale(identifier: language ?? interfaceLanguage), arguments: arguments)
    }
}
