import Foundation
import FluentIMECore

final class LanguagePreferences {
    let mode: InputMode
    private let defaults: UserDefaults
    init(_ mode: InputMode, defaults: UserDefaults = .standard) { self.mode = mode; self.defaults = defaults }
    private func value(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: "input." + mode.rawValue + "." + key) as? Bool ?? defaults.object(forKey: key) as? Bool ?? fallback
    }
    private func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey: "input." + mode.rawValue + "." + key)
        NotificationCenter.default.post(name: Preferences.changed, object: Preferences.shared)
    }
    var autoCorrection: Bool { get { value("autoCorrection", fallback: true) } set { set("autoCorrection", newValue) } }
    var abbreviation: Bool { get { value("abbreviation", fallback: true) } set { set("abbreviation", newValue) } }
    var halfWidth: Bool { get { value("halfWidth", fallback: true) } set { set("halfWidth", newValue) } }
    var englishPunctuation: Bool { get { value("englishPunctuation", fallback: false) } set { set("englishPunctuation", newValue) } }
    var learning: Bool { get { value("learning", fallback: true) } set { set("learning", newValue) } }
    var wanxiangGrammar: Bool { get { value("wanxiangGrammar", fallback: true) } set { set("wanxiangGrammar", newValue) } }
    var neuralRanking: Bool { get { value("neuralRanking", fallback: false) } set { set("neuralRanking", newValue); if newValue { NeuralRuntime.shared.ranker?.prewarm() } } }
    var fuzzyPinyinMask: Int {
        get { (defaults.object(forKey: "input." + mode.rawValue + ".fuzzyPinyinMask") as? Int ?? defaults.integer(forKey: "fuzzyPinyinMask")) & FuzzyPinyinRule.validMask }
        set { set("fuzzyPinyinMask", newValue & FuzzyPinyinRule.validMask) }
    }
}
extension Preferences {
    func inputOptions(for mode: InputMode) -> InputOptions {
        let language = LanguagePreferences(mode)
        var options = inputOptions
        options.autoCorrection = language.autoCorrection; options.abbreviation = language.abbreviation
        options.halfWidth = language.halfWidth; options.englishPunctuation = language.englishPunctuation
        options.learning = language.learning; options.fuzzyPinyinMask = language.fuzzyPinyinMask
        options.wanxiangGrammar = language.wanxiangGrammar; options.neuralRanking = language.neuralRanking
        return options
    }
}
