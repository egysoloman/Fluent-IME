import Foundation

/// Keep automatic syllable spaces visible while Rime translates only the prefix
/// before its editing caret. The extra space marks the current internal split.
struct PinyinPreedit {
    private var previousRaw = ""
    private var boundaries = Set<Int>()
    mutating func format(_ composition: inout Composition, caret: Int) {
        let raw = Array(composition.rawInput)
        guard !raw.isEmpty, !composition.preedit.unicodeScalars.contains(where: ChineseTokenizer.isHan) else {
            if raw.isEmpty { previousRaw = ""; boundaries = [] }
            return
        }
        let spelling = Array(composition.preedit.filter { $0 != " " && $0 != "'" })
        guard spelling.count == raw.filter({ $0 != "'" }).count else { return }
        if previousRaw != composition.rawInput {
            if caret == raw.count || previousRaw.isEmpty {
                boundaries = []; var offset = 0
                for letter in composition.preedit {
                    if letter == " " || letter == "'" {
                        if offset < raw.count && raw[offset] == "'" { offset += 1 }
                        else { boundaries.insert(offset) }
                    } else { offset += 1 }
                }
            } else {
                let old = Array(previousRaw)
                var prefix = 0, suffix = 0
                while prefix < min(old.count, raw.count), old[prefix] == raw[prefix] { prefix += 1 }
                while suffix < min(old.count, raw.count) - prefix, old[old.count - 1 - suffix] == raw[raw.count - 1 - suffix] { suffix += 1 }
                boundaries = Set(boundaries.compactMap { boundary in
                    if boundary <= prefix { return boundary }
                    if boundary >= old.count - suffix { return boundary + raw.count - old.count }
                    return nil
                })
            }
            previousRaw = composition.rawInput
        }
        var result = "", cursor = 0, index = 0
        for (position, letter) in raw.enumerated() {
            if position == caret { cursor = result.utf16.count }
            if position > 0, boundaries.contains(position) || position == caret {
                if result.last != " " { result.append(" ") }
            }
            if letter == "'" { if result.last != " " { result.append(" ") } }
            else { result.append(spelling[index]); index += 1 }
        }
        if caret >= raw.count { cursor = result.utf16.count }
        composition.preedit = result; composition.cursorUTF16 = cursor
    }
}
