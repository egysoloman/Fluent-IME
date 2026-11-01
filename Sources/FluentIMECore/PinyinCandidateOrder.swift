import Foundation

/// Keep exact spellings ahead of fuzzy alternatives within the first candidate
/// page. The spellings come from Rime's spelling_hints, not guessed from Hanzi.
enum PinyinCandidateOrder {
    static func prioritizeExact(_ candidates: [Candidate], preedit: String, cursorUTF16: Int, order: [Int]? = nil) -> [Int] {
        let order = order ?? Array(candidates.indices)
        let prefix = (preedit as NSString).substring(to: max(0, min(cursorUTF16, (preedit as NSString).length)))
        // A partially selected phrase can have a confirmed Hanzi prefix. Only
        // compare the remaining spelling to the left of the composition caret.
        let active = String(prefix.reversed().prefix { isPinyin($0) }.reversed())
        let spelling = normalized(active)
        guard !spelling.isEmpty else { return order }
        func exact(_ index: Int) -> Bool {
            let hint = candidates[index].comment
            guard !hint.isEmpty && hint.allSatisfy(isPinyin) else { return false }
            if normalized(hint) == spelling { return true }
            let typed = active.lowercased().split(whereSeparator: { $0 == " " || $0 == "'" }).map { normalized(String($0)) }
            let full = hint.lowercased().split(whereSeparator: { $0 == " " || $0 == "'" }).map { normalized(String($0)) }
            return typed.count == full.count && zip(typed, full).allSatisfy { !$0.isEmpty && $1.hasPrefix($0) }
        }
        return order.filter(exact) + order.filter { !exact($0) }
    }

    private static func isPinyin(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || " '".contains(character)) || character == "ü"
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ü", with: "v").filter { $0 != " " && $0 != "'" }
    }
}
