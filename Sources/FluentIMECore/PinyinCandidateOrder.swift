import Foundation

/// Keep exact spellings ahead of corrected and fuzzy alternatives within the first
/// candidate page. The spellings come from Rime's spelling_hints, not guessed from Hanzi.
enum PinyinCandidateOrder {
    static func prioritizeExact(_ candidates: [Candidate], preedit: String, cursorUTF16: Int, order: [Int]? = nil) -> [Int] {
        let order = order ?? Array(candidates.indices)
        let prefix = (preedit as NSString).substring(to: max(0, min(cursorUTF16, (preedit as NSString).length)))
        // A partially selected phrase can have a confirmed Hanzi prefix. Only
        // compare the remaining spelling to the left of the composition caret.
        let active = String(prefix.reversed().prefix { isPinyin($0) }.reversed())
        let spelling = normalized(active)
        guard !spelling.isEmpty else { return order }
        let typed = active.lowercased().split(whereSeparator: { $0 == " " || $0 == "'" }).map { normalized(String($0)) }
        // 0 exact, 1 corrected full syllables, 2 initials/prefixes, 3 everything else.
        func rank(_ index: Int) -> Int {
            let hint = candidates[index].comment
            guard !hint.isEmpty && hint.allSatisfy(isPinyin) else { return 3 }
            if normalized(hint) == spelling { return 0 }
            let full = hint.lowercased().split(whereSeparator: { $0 == " " || $0 == "'" }).map { normalized(String($0)) }
            if typed.count == full.count && zip(typed, full).allSatisfy({ !$0.isEmpty && $1.hasPrefix($0) }) { return 2 }
            return isCorrectedFullPinyin(spelling: spelling, syllables: full) ? 1 : 3
        }
        let ranks = Dictionary(uniqueKeysWithValues: order.map { ($0, rank($0)) })
        return (0...3).flatMap { tier in order.filter { ranks[$0] == tier } }
    }

    private static let keyboardRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private static let qwertyNeighbors: [Character: Set<Character>] = {
        var result: [Character: Set<Character>] = [:]
        for (r, row) in keyboardRows.enumerated() {
            let keys = Array(row)
            for (c, key) in keys.enumerated() {
                var near = Set<Character>()
                if c > 0 { near.insert(keys[c - 1]) }
                if c + 1 < keys.count { near.insert(keys[c + 1]) }
                for other in [r - 1, r + 1] where keyboardRows.indices.contains(other) {
                    let keys2 = Array(keyboardRows[other])
                    for d in [c - 1, c, c + 1] where keys2.indices.contains(d) { near.insert(keys2[d]) }
                }
                result[key] = near
            }
        }
        return result
    }()

    /// The typed spelling is the dictionary spelling with up to two adjacent-key
    /// substitutions or one transposition inside each full syllable.
    private static func isCorrectedFullPinyin(spelling: String, syllables full: [String]) -> Bool {
        guard spelling.contains(where: { "aeiouv".contains($0) }), !full.isEmpty,
              full.allSatisfy({ $0.count >= 2 }), full.reduce(0, { $0 + $1.count }) == spelling.count else { return false }
        var rest = Substring(spelling)
        for syllable in full {
            let typed = Array(rest.prefix(syllable.count)), target = Array(syllable)
            rest = rest.dropFirst(syllable.count)
            if typed == target { continue }
            let differing = typed.indices.filter { typed[$0] != target[$0] }
            if differing.count == 2, differing[1] == differing[0] + 1,
               typed[differing[0]] == target[differing[1]], typed[differing[1]] == target[differing[0]] { continue }
            guard differing.count <= 2, differing.allSatisfy({ qwertyNeighbors[target[$0]]?.contains(typed[$0]) == true }) else { return false }
        }
        return true
    }

    private static func isPinyin(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || " '".contains(character)) || character == "ü"
    }
    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ü", with: "v").filter { $0 != " " && $0 != "'" }
    }
}
