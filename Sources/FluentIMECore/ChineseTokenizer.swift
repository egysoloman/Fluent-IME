import Foundation

/// BERT BasicTokenizer + WordPiece for the pinned HFL vocabulary.
public struct ChineseTokenizer {
    private let vocabulary: [String: Int32]
    public let cls: Int32, sep: Int32, mask: Int32, unknown: Int32
    public init(vocabularyURL: URL) throws {
        // Vocabulary entries themselves include Unicode line separators. Only LF
        // separates records; CharacterSet.newlines silently shifts token IDs.
        let lines = try String(contentsOf: vocabularyURL, encoding: .utf8).components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        vocabulary = Dictionary(lines.enumerated().filter { !$0.element.isEmpty }.map { ($0.element, Int32($0.offset)) }, uniquingKeysWith: { first, _ in first })
        cls = vocabulary["[CLS]"] ?? 101; sep = vocabulary["[SEP]"] ?? 102
        mask = vocabulary["[MASK]"] ?? 103; unknown = vocabulary["[UNK]"] ?? 100
    }
    public static func isHan(_ scalar: UnicodeScalar) -> Bool {
        [0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x30000...0x323AF].contains { $0.contains(Int(scalar.value)) }
    }
    public func encode(_ text: String) -> [Int32] {
        var words: [String] = [], word = ""
        func flush() { if !word.isEmpty { words.append(word); word = "" } }
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            if CharacterSet.nonBaseCharacters.contains(scalar) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { flush(); continue }
            if CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0xFFFD { continue }
            if Self.isHan(scalar) || CharacterSet.punctuationCharacters.contains(scalar) || (33...47).contains(scalar.value) || (58...64).contains(scalar.value) || (91...96).contains(scalar.value) || (123...126).contains(scalar.value) {
                flush(); words.append(String(scalar))
            } else { word.unicodeScalars.append(scalar) }
        }
        flush()
        return words.flatMap { word -> [Int32] in
            let chars = Array(word)
            guard chars.count <= 100 else { return [unknown] }
            var result: [Int32] = [], start = 0
            while start < chars.count {
                var end = chars.count, found: Int32?
                while end > start {
                    let piece = (start > 0 ? "##" : "") + String(chars[start..<end])
                    if let id = vocabulary[piece] { found = id; break }
                    end -= 1
                }
                guard let found else { return [unknown] }
                result.append(found); start = end
            }
            return result
        }
    }
}
