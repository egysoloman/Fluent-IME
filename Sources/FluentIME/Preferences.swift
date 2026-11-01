import AppKit
import FluentKit
import FluentIMECore

final class Preferences {
    static let shared = Preferences()
    static let changed = Notification.Name("FluentIMEPreferencesChanged")
    private let defaults = UserDefaults.standard
    private var compositionExpanded = false

    var interfaceLanguage: String {
        get { defaults.string(forKey: "interfaceLanguage") ?? "system" }
        set { guard ["system", "zh-Hans", "zh-Hant", "en"].contains(newValue) else { return }; defaults.set(newValue, forKey: "interfaceLanguage"); notify() }
    }
    var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "system" }
        set { defaults.set(newValue, forKey: "appearance"); notify() }
    }
    var expandedCandidates: Bool {
        get { candidateExpansionEnabled && (ProcessInfo.processInfo.environment["FLUENTIME_RENDER_EXPANDED"] == "1" || compositionExpanded) }
        set { let value = newValue && candidateExpansionEnabled; guard value != compositionExpanded else { return }; compositionExpanded = value; notify() }
    }
    var candidateExpansionEnabled: Bool {
        get { ProcessInfo.processInfo.environment["FLUENTIME_RENDER_EXPANDED"] == "1" || defaults.bool(forKey: "candidateExpansionEnabled") }
        set {
            defaults.set(newValue, forKey: "candidateExpansionEnabled")
            if !newValue { compositionExpanded = false }
            notify()
        }
    }
    var candidateExpansionAnimation: Bool {
        get { defaults.object(forKey: "candidateExpansionAnimation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "candidateExpansionAnimation"); notify() }
    }
    var englishPunctuation: Bool {
        get { defaults.bool(forKey: "englishPunctuation") }
        set { defaults.set(newValue, forKey: "englishPunctuation"); notify() }
    }
    var shiftSwitch: Bool {
        get { defaults.object(forKey: "shiftSwitch") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shiftSwitch"); notify() }
    }
    var startsInEnglish: Bool {
        get { defaultInputMode == .english }
        set { defaultInputMode = newValue ? .english : .simplifiedChinese }
    }
    var enabledInputModes: [InputMode] {
        get { InputMode.normalized(defaults.stringArray(forKey: "enabledInputModes")?.compactMap(InputMode.init(rawValue:)) ?? InputMode.allCases) }
        set {
            let modes = InputMode.normalized(newValue)
            let previousDefault = defaultInputMode
            defaults.set(modes.map(\.rawValue), forKey: "enabledInputModes")
            if !modes.contains(previousDefault) { defaults.set(modes[0].rawValue, forKey: "defaultInputMode") }
            notify()
        }
    }
    var defaultInputMode: InputMode {
        get {
            let requested = defaults.string(forKey: "defaultInputMode").flatMap(InputMode.init(rawValue:)) ?? (defaults.bool(forKey: "startsInEnglish") ? .english : .simplifiedChinese)
            return enabledInputModes.contains(requested) ? requested : enabledInputModes[0]
        }
        set { guard enabledInputModes.contains(newValue) else { return }; defaults.set(newValue.rawValue, forKey: "defaultInputMode"); notify() }
    }
    var showInputModeIndicator: Bool {
        get { defaults.bool(forKey: "showInputModeIndicator") }
        set { defaults.set(newValue, forKey: "showInputModeIndicator"); notify() }
    }
    var advancedEffects: Bool {
        get { defaults.bool(forKey: "advancedEffects") }
        set { defaults.set(newValue, forKey: "advancedEffects"); notify() }
    }
    var halfWidth: Bool {
        get { defaults.object(forKey: "halfWidth") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "halfWidth"); notify() }
    }
    var autoCorrection: Bool {
        get { defaults.object(forKey: "autoCorrection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCorrection"); notify() }
    }
    var abbreviation: Bool {
        get { defaults.object(forKey: "abbreviation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "abbreviation"); notify() }
    }
    var learning: Bool {
        get { defaults.object(forKey: "learning") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "learning"); notify() }
    }
    var fuzzyPinyinMask: Int {
        get { defaults.integer(forKey: "fuzzyPinyinMask") & FuzzyPinyinRule.validMask }
        set { defaults.set(newValue & FuzzyPinyinRule.validMask, forKey: "fuzzyPinyinMask"); notify() }
    }
    var candidatePopupAnimation: Bool {
        get {
            if let value = ProcessInfo.processInfo.environment["FLUENTIME_RENDER_POPUP_ANIMATION"] { return value == "1" }
            return defaults.bool(forKey: "candidatePopupAnimation")
        }
        set { defaults.set(newValue, forKey: "candidatePopupAnimation"); notify() }
    }
    var candidatePageAnimation: Bool {
        get { defaults.object(forKey: "candidatePageAnimation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "candidatePageAnimation"); notify() }
    }
    var keepCandidateSelectionOnPage: Bool {
        get { defaults.object(forKey: "keepCandidateSelectionOnPage") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepCandidateSelectionOnPage"); notify() }
    }
    var neuralRanking: Bool {
        get { defaults.object(forKey: "neuralRanking") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "neuralRanking"); if newValue { NeuralRuntime.shared.ranker?.prewarm() }; notify() }
    }
    var wanxiangGrammar: Bool {
        get { defaults.object(forKey: "wanxiangGrammar") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wanxiangGrammar"); notify() }
    }
    var setupCompleted: Bool {
        get { defaults.bool(forKey: "setupCompleted") }
        set { defaults.set(newValue, forKey: "setupCompleted") }
    }
    var clipboardRecording: Bool {
        get { defaults.bool(forKey: "clipboardRecording") }
        set { defaults.set(newValue, forKey: "clipboardRecording"); ClipboardHistory.shared.setRecording(newValue); notify() }
    }
    var clipboardRetention: Int {
        get { let value = defaults.object(forKey: "clipboardRetention") as? Int ?? 1800; return [0, 900, 1800, 3600, 86400, 604800].contains(value) ? value : 1800 }
        set { defaults.set(newValue, forKey: "clipboardRetention"); ClipboardHistory.shared.setRetention(TimeInterval(clipboardRetention)); notify() }
    }
    var theme: FluentTheme {
        let override = ProcessInfo.processInfo.environment["FLUENTIME_RENDER_THEME"]
        let appearance = override ?? self.appearance
        return FluentTheme(accent: NSColor(srgbRed: 0, green: 103/255, blue: 192/255, alpha: 1),
                    colorScheme: appearance == "dark" ? .dark : appearance == "light" ? .light : .system,
                    typography: FluentTypography(fontProvider: IMEFont.provider))
            .with(materialConfiguration: .init(material: .nativeAcrylic, isEnabled: advancedEffects), for: .transient)
    }
    var inputOptions: InputOptions { InputOptions(shiftSwitch: shiftSwitch, englishPunctuation: englishPunctuation, startsInEnglish: startsInEnglish, halfWidth: halfWidth, autoCorrection: autoCorrection, abbreviation: abbreviation, learning: learning, fuzzyPinyinMask: fuzzyPinyinMask, expandedCandidates: expandedCandidates, bracketsExpandCandidates: candidateExpansionEnabled, neuralRanking: neuralRanking, wanxiangGrammar: wanxiangGrammar, keepCandidateSelectionOnPage: keepCandidateSelectionOnPage, enabledModes: enabledInputModes, defaultMode: defaultInputMode) }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
