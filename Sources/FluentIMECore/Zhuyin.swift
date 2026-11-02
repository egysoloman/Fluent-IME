import Foundation

/// The keyboard an input source types with. Zhuyin is its own macOS input source
/// (`Fluent 注音`) and never shares Pinyin's schema or key handling.
public enum InputKeyboard: String {
    case pinyin, zhuyin
    public static let zhuyinSourceID = "org.fluentime.inputmethod.FluentIME.Bopomofo"
    public init(sourceID: String) { self = sourceID == Self.zhuyinSourceID ? .zhuyin : .pinyin }
}

/// The Dai-Chien (大千) layout printed on Zhuyin keycaps, matching
/// `Resources/fluent_bopomofo.schema.template.yaml`.
public enum ZhuyinLayout {
    static let keys = Array("1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347")
    static let symbols = Array("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˊˇˋ˙")
    private static let table = Dictionary(uniqueKeysWithValues: zip(keys, symbols))
    /// Tone keys and the apostrophe that Space inserts for the first tone end a syllable.
    static let syllableEnds: Set<Character> = ["3", "4", "6", "7", "'"]
    /// Shows untranslated keys as Zhuyin; the first-tone apostrophe has no mark.
    public static func display(_ text: String) -> String {
        String(text.compactMap { $0 == "'" ? nil : table[$0] ?? $0 })
    }
}
