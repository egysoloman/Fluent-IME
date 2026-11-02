import AppKit
import Carbon

public struct InputOptions {
    public var shiftSwitch: Bool
    public var englishPunctuation: Bool
    public var startsInEnglish: Bool
    public var halfWidth: Bool
    public var autoCorrection: Bool
    public var abbreviation: Bool
    public var learning: Bool
    public var fuzzyPinyinMask: Int
    public var bracketsExpandCandidates: Bool
    public var expandedCandidates: Bool
    public var neuralRanking: Bool
    public var wanxiangGrammar: Bool
    public var keepCandidateSelectionOnPage: Bool
    public var enabledModes: [InputMode]
    public var defaultMode: InputMode?
    /// Set by the session from the active input source, not by preferences.
    public var keyboard: InputKeyboard = .pinyin
    var modes: [InputMode] { InputMode.normalized(enabledModes) }
    var initialMode: InputMode {
        let requested = defaultMode ?? (startsInEnglish ? .english : .simplifiedChinese)
        let modes = InputMode.normalized(enabledModes)
        return modes.contains(requested) ? requested : modes[0]
    }
    var schemaID: String {
        // Zhuyin has its own toned dictionary: no abbreviation, correction, fuzzy-pinyin
        // or Simplified-Chinese grammar variants.
        if keyboard == .zhuyin { return "fluent_bopomofo_l\(learning ? 1 : 0)" }
        let mask = fuzzyPinyinMask & FuzzyPinyinRule.validMask
        return "fluent_pinyin_a\(abbreviation ? 1 : 0)_c\(autoCorrection ? 1 : 0)_l\(learning ? 1 : 0)" + (mask == 0 ? "" : "_f\(mask)") + (wanxiangGrammar ? "_g1" : "")
    }
    public init(shiftSwitch: Bool = true, englishPunctuation: Bool = false, startsInEnglish: Bool = false, halfWidth: Bool = true, autoCorrection: Bool = false, abbreviation: Bool = true, learning: Bool = true, fuzzyPinyinMask: Int = 0, expandedCandidates: Bool = false, bracketsExpandCandidates: Bool = false, neuralRanking: Bool = false, wanxiangGrammar: Bool = false, keepCandidateSelectionOnPage: Bool = true, enabledModes: [InputMode] = InputMode.allCases, defaultMode: InputMode? = nil) {
        self.shiftSwitch = shiftSwitch; self.englishPunctuation = englishPunctuation
        self.startsInEnglish = startsInEnglish; self.halfWidth = halfWidth
        self.autoCorrection = autoCorrection; self.abbreviation = abbreviation; self.learning = learning
        self.fuzzyPinyinMask = fuzzyPinyinMask
        self.expandedCandidates = expandedCandidates
        self.bracketsExpandCandidates = bracketsExpandCandidates
        self.neuralRanking = neuralRanking
        self.wanxiangGrammar = wanxiangGrammar
        self.keepCandidateSelectionOnPage = keepCandidateSelectionOnPage
        self.enabledModes = InputMode.normalized(enabledModes); self.defaultMode = defaultMode
    }
}

/// Shared by the real IMK controller and the interactive local test area.
public final class InputSession {
    public let rime: RimeSession
    public private(set) var mode: InputMode = .simplifiedChinese
    public var isChinese: Bool { mode.isChinese }
    public private(set) var keyboard: InputKeyboard
    /// The modes Shift and the mode menu cycle through on the current keyboard.
    public var availableModes: [InputMode] { options().modes }
    private var zhuyinListOpen = false
    public var nextMode: InputMode {
        let modes = options().modes
        return modes[(modes.firstIndex(of: mode).map { $0 + 1 } ?? 0) % modes.count]
    }
    private var shift = ShiftTapTracker()
    private let baseOptions: () -> InputOptions
    private let languageOptions: ((InputMode) -> InputOptions)?
    private func options() -> InputOptions {
        var result = languageOptions?(mode) ?? baseOptions(); result.keyboard = keyboard
        return result
    }
    private var appliedOptions: InputOptions
    public var onCommit: ((String) -> Void)?
    public var onUpdate: ((Composition) -> Void)?
    public var onExpansionChange: ((Bool) -> Void)?
    private var expandedKey = ""
    private var expandedItems: [Candidate] = []
    private var expandedHasMore = false
    private var numberedRowStart = 0
    private var expandedColumns = 6
    private var pinyinPreedit = PinyinPreedit()
    private let rankingClock: () -> TimeInterval
    private let ranker: CandidateReranking?
    private var rankingTicket: RankingTicket?
    private var rankingGeneration = 0
    private var rankingKey = ""
    private var rankingOrder: [Int]?
    private var rankingLocked = false
    private var recentContext = ""
    private var wasComposing = false
    public var composition: Composition {
        var result = baseComposition
        if keyboard == .zhuyin { presentZhuyin(&result); return result }
        if let order = rankingOrder, key(for: result) == rankingKey, order.count <= result.candidates.count {
            let original = result.candidates, indices = result.candidateIndices
            let selectedID = indices.indices.contains(result.highlighted) ? indices[result.highlighted] : -1
            for (slot, index) in order.enumerated() { result.candidates[slot] = original[index]; result.candidateIndices[slot] = indices[index] }
            result.highlighted = result.candidateIndices.firstIndex(of: selectedID) ?? 0
        }
        return result
    }
    private var baseComposition: Composition {
        var result = rawComposition
        guard keyboard == .pinyin, appliedOptions.fuzzyPinyinMask != 0 || appliedOptions.autoCorrection, result.page == 0 || result.isContinuous else { return result }
        let candidates = Array(result.candidates.prefix(result.pageSize))
        let order = PinyinCandidateOrder.prioritizeExact(candidates, preedit: result.preedit, cursorUTF16: result.cursorUTF16)
        let indices = result.candidateIndices
        let selectedID = indices.indices.contains(result.highlighted) ? indices[result.highlighted] : -1
        for (slot, index) in order.enumerated() {
            result.candidates[slot] = candidates[index]; result.candidateIndices[slot] = indices[index]
        }
        result.highlighted = result.candidateIndices.firstIndex(of: selectedID) ?? 0
        return result
    }
    private var rawComposition: Composition {
        var result = rime.composition
        guard keyboard == .pinyin else { return result }
        pinyinPreedit.format(&result, caret: rime.caretPosition)
        if result.isComposing && result.candidates.isEmpty {
            result.candidates = [Candidate(result.rawInput)]
            result.candidateIndices = [-1] // Explicit raw-input fallback, not a Rime index.
            result.highlighted = 0; result.page = 0; result.isLastPage = true
            return result
        }
        guard options().expandedCandidates, result.isComposing else { return result }
        let key = result.rawInput + "\u{0}" + result.preedit + "\u{0}" + appliedOptions.schemaID
        if key != expandedKey {
            expandedKey = key; expandedItems = []; expandedHasMore = true
            numberedRowStart = ((result.page * result.pageSize + result.highlighted) / expandedColumns) * expandedColumns
        }
        let selected = result.page * result.pageSize + result.highlighted
        while expandedItems.count <= selected && expandedHasMore { appendCandidates() }
        result.candidates = expandedItems
        result.candidateIndices = Array(expandedItems.indices)
        result.highlighted = selected
        result.isContinuous = true; result.hasMoreCandidates = expandedHasMore
        return result
    }

    private func appendCandidates() {
        let batch = rime.candidates(from: expandedItems.count)
        expandedItems += batch.items; expandedHasMore = batch.hasMore && !batch.items.isEmpty
    }
    public func loadMoreCandidates() {
        guard composition.isContinuous, expandedHasMore else { return }
        appendCandidates(); onUpdate?(composition)
    }
    public func setCandidateViewport(start: Int, columns: Int) {
        numberedRowStart = max(0, start); expandedColumns = max(1, min(9, columns))
    }

    public init(engine: RimeEngine, keyboard: InputKeyboard = .pinyin, options: @escaping () -> InputOptions = { InputOptions() }, ranker: CandidateReranking? = nil, languageOptions: ((InputMode) -> InputOptions)? = nil, rankingClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        rime = try engine.makeSession()
        self.ranker = ranker; self.rankingClock = rankingClock
        self.baseOptions = options; self.languageOptions = languageOptions; self.keyboard = keyboard
        var initial = options(); initial.keyboard = keyboard
        let initialMode = initial.initialMode
        mode = initialMode
        appliedOptions = languageOptions?(initialMode) ?? options()
        appliedOptions.keyboard = keyboard
        guard rime.selectSchema(appliedOptions.schemaID) else { throw EngineError.sessionUnavailable }
        rime.setOption("ascii_punct", appliedOptions.englishPunctuation)
        applyScript()
    }

    public func applyOptions(preservingComposition: Bool = false) {
        let current = options()
        let schemaChanged = current.schemaID != appliedOptions.schemaID
        let pending = schemaChanged && preservingComposition ? rime.composition.rawInput : ""
        let caret = rime.caretPosition
        if schemaChanged {
            if preservingComposition { rime.clear() } else { finish() }
            guard rime.selectSchema(current.schemaID) else { return }
        }
        // Rime rebuilds the menu when an option is set, even when its value has
        // not changed. Reapply only for a preference/schema change so the next
        // number, Space or paging key keeps the page currently shown to the user.
        if schemaChanged || current.englishPunctuation != appliedOptions.englishPunctuation {
            rime.setOption("ascii_punct", current.englishPunctuation)
        }
        let modeChanged = current.initialMode != appliedOptions.initialMode || !current.modes.contains(mode)
        appliedOptions = current
        if modeChanged { selectMode(current.initialMode) }
        else if schemaChanged { applyScript() }
        if !pending.isEmpty {
            for byte in pending.utf8 { rime.process(key: Int32(byte)) }
            rime.caretPosition = caret
        }
        if !current.neuralRanking { resetContext() }
    }

    public func handle(_ event: NSEvent) -> Bool {
        applyOptions()
        if event.type == .flagsChanged {
            if event.keyCode == 57 {
                // macOS owns the hold-to-Caps-Lock gesture; finalize the marked Latin
                // spelling before letting the host receive uppercase key events.
                finishRaw()
                return false
            }
            if shift.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags), options().shiftSwitch {
                toggleLanguage()
                return true
            }
            return false
        }
        guard event.type == .keyDown else { return false }
        shift.cancel()
        let flags = event.modifierFlags
        if flags.contains(.capsLock) {
            finishRaw()
            return false
        }
        if !flags.intersection([.command, .control, .option]).isEmpty {
            // Finish the inline composition before forwarding an application shortcut.
            finish()
            resetContext()
            return false
        }
        guard isChinese else { return false }
        guard let key = RimeKey.translate(keyCode: event.keyCode, characters: event.characters ?? "") else { return false }
        if keyboard == .zhuyin { return handleZhuyin(key, flags: flags) }
        let current = composition
        if !current.isComposing { resetContextForEditingKey(key) }
        if current.isComposing, options().bracketsExpandCandidates, let changeExpansion = onExpansionChange {
            if !current.isContinuous && key == 93 {
                lockRanking(); changeExpansion(true); publish(); return true
            }
            if current.isContinuous && key == 91 && numberedRowStart == 0 && current.highlighted < expandedColumns {
                lockRanking(); changeExpansion(false); publish(); return true
            }
        }
        if current.isComposing, key == RimeKey.left || key == RimeKey.right {
            let caret = rime.caretPosition, end = current.rawInput.utf8.count
            if caret < end || (key == RimeKey.left && current.highlighted == 0) {
                invalidateRanking(); lockRanking(); expandedKey = ""
                if caret == end && key == RimeKey.left {
                    // Ask Rime's navigator for the real previous syllable boundary,
                    // including implicit segmentation and apostrophe delimiters.
                    _ = rime.process(key: RimeKey.left, modifiers: 1 << 2)
                } else if key == RimeKey.left {
                    // Rewind follows Rime's cached syllable spans at boundaries,
                    // and moves one character when the split lies inside a span.
                    if caret > 0 { _ = rime.process(key: RimeKey.left) }
                } else {
                    // Right advances the split one character, even at boundaries.
                    rime.caretPosition = min(end, caret + 1)
                }
                publish(selectFirst: true); return true
            }
        }
        if current.isComposing && !current.candidates.isEmpty {
            if !current.isContinuous, (49...55).contains(key), current.candidates.indices.contains(Int(key - 49)) {
                choose(Int(key - 49)); return true
            }
            if key == 32 { choose(current.highlighted); return true }
            if [RimeKey.left, RimeKey.right, RimeKey.up, RimeKey.down, RimeKey.tab, RimeKey.pageUp, RimeKey.pageDown, 91, 93, 45, 61].contains(key) { lockRanking() }
            if !current.isContinuous, [RimeKey.pageUp, RimeKey.pageDown, 91, 93, 45, 61].contains(key) {
                page(backward: [RimeKey.pageUp, 91, 45].contains(key)); return true
            }
            if !current.isContinuous, [RimeKey.left, RimeKey.right, RimeKey.up, RimeKey.down, RimeKey.tab].contains(key) {
                let backwards = key == RimeKey.left || key == RimeKey.up || (key == RimeKey.tab && flags.contains(.shift))
                let destination = current.highlighted + (backwards ? -1 : 1)
                if current.candidateIndices.indices.contains(destination) {
                    _ = rime.highlightAbsolute(current.candidateIndices[destination])
                } else if backwards ? current.page > 0 : !current.isLastPage {
                    _ = rime.process(key: backwards ? RimeKey.pageUp : RimeKey.pageDown)
                    let next = composition
                    if let index = backwards ? next.candidateIndices.last : next.candidateIndices.first { _ = rime.highlightAbsolute(index) }
                }
                publish(); return true
            }
        }
        if current.isContinuous && !current.candidates.isEmpty {
            if (49...57).contains(key) {
                let offset = Int(key - 49)
                if offset < expandedColumns, current.candidates.indices.contains(numberedRowStart + offset) { choose(numberedRowStart + offset) }
                return true
            }
            if key == 32 { choose(current.highlighted); return true }
            if [91, 93, 45, 61].contains(key) {
                page(backward: key == 91 || key == 45); return true
            }
            var delta: Int?
            switch key {
            case RimeKey.left: delta = -1
            case RimeKey.right: delta = 1
            case RimeKey.tab: delta = flags.contains(.shift) ? -1 : 1
            case RimeKey.up: delta = -expandedColumns
            case RimeKey.down: delta = expandedColumns
            case RimeKey.pageUp: delta = -expandedColumns * 5
            case RimeKey.pageDown: delta = expandedColumns * 5
            default: break
            }
            if let delta {
                moveExpandedSelection(to: current.highlighted + delta); return true
            }
        }
        if key == RimeKey.enter, composition.isComposing {
            let raw = composition.rawInput
            rime.clear()
            resetContext()
            onCommit?(outputText(raw))
            publish()
            return true
        }
        if ![RimeKey.pageUp, RimeKey.pageDown, 91, 93, 45, 61].contains(key) { invalidateRanking(); rankingLocked = false }
        let handled = rime.process(key: key, modifiers: flags.contains(.shift) ? 1 : 0)
        publish(selectFirst: handled && current.rawInput != rime.composition.rawInput)
        if !handled, !options().halfWidth, (0x20...0x7e).contains(key), !composition.isComposing {
            onCommit?(outputText(String(UnicodeScalar(UInt32(key))!)))
            return true
        }
        return handled
    }

    /// Switches between the Pinyin and Zhuyin input sources, finishing any composition first.
    public func setKeyboard(_ next: InputKeyboard) {
        guard next != keyboard else { return }
        finish(); zhuyinListOpen = false
        keyboard = next
        expandedKey = ""; expandedItems = []
        applyOptions()
        if !options().modes.contains(mode) { selectMode(options().initialMode) }
        publish()
    }
    /// Pinyin's dictionary is Simplified and Zhuyin's Traditional; each converts to the other.
    private func applyScript() {
        if keyboard == .zhuyin { rime.setOption("simplification", mode == .simplifiedChinese) }
        else { rime.setOption("traditional", mode == .traditionalChinese) }
    }
    /// Zhuyin on 大千. Rime's speller parses Zhuyin, tones (Space is the first tone) and
    /// syllables; Fluent only decides when the candidate list is shown and what selects.
    /// - Typing converts inline and keeps the list hidden. A typed tone narrows candidates.
    /// - ↓, or a Space that Rime does not take as the first tone, opens the list.
    /// - List open: 1–9 or Shift+1–9 choose, ← ↑ / → ↓ move the highlight, Space or
    ///   PageDown and PageUp page, Enter chooses, Esc closes; other keys keep typing.
    /// - List closed: Enter commits the converted text, Esc clears, ← / → move the caret
    ///   so the list offers candidates for the text before it, Shift+digits type symbols.
    private static let shiftedDigits: [Int32] = "!@#$%^&*(".unicodeScalars.map { Int32($0.value) }
    private func handleZhuyin(_ key: Int32, flags: NSEvent.ModifierFlags) -> Bool {
        let current = rime.composition
        if !current.isComposing { zhuyinListOpen = false }
        if zhuyinListOpen {
            let menu = composition
            let slot = (49...57).contains(key) ? Int(key - 49) : Self.shiftedDigits.firstIndex(of: key)
            if let slot {
                // Choose while the list is still shown; Rime keeps the rest composing.
                if menu.candidates.indices.contains(slot) { choose(slot); zhuyinListOpen = false; publish() }
                return true
            }
            switch key {
            case RimeKey.enter: choose(menu.highlighted); zhuyinListOpen = false; publish(); return true
            case RimeKey.escape: zhuyinListOpen = false; publish(); return true
            case RimeKey.left, RimeKey.up, RimeKey.right, RimeKey.down:
                let backwards = key == RimeKey.left || key == RimeKey.up
                let destination = menu.highlighted + (backwards ? -1 : 1)
                if menu.candidateIndices.indices.contains(destination) { _ = rime.highlightAbsolute(menu.candidateIndices[destination]); publish() }
                else { page(backward: backwards) }
                return true
            case 32, RimeKey.pageDown: page(backward: false); return true
            case RimeKey.pageUp: page(backward: true); return true
            default: zhuyinListOpen = false
            }
        }
        if current.isComposing {
            switch key {
            case RimeKey.down: zhuyinListOpen = true; publish(selectFirst: true); return true
            case RimeKey.enter: rime.commit(); resetContext(); publish(); return true
            case RimeKey.left, RimeKey.right:
                let caret = rime.caretPosition
                if key == RimeKey.left ? caret > 0 : caret < current.rawInput.utf8.count { _ = rime.process(key: key) }
                publish(selectFirst: true); return true
            default: break
            }
        }
        let handled = rime.process(key: key, modifiers: flags.contains(.shift) ? 1 : 0)
        if key == 32, current.isComposing, rime.composition.rawInput == current.rawInput {
            zhuyinListOpen = true; publish(selectFirst: true); return true
        }
        publish(selectFirst: handled && rime.composition.rawInput != current.rawInput)
        return handled
    }
    /// Inline text is the converted sentence; untranslated keys show as Zhuyin. The
    /// candidate list appears only after Space or ↓.
    private func presentZhuyin(_ result: inout Composition) {
        guard result.isComposing else { return }
        let raw = Array(result.rawInput.utf8), caret = min(max(0, rime.caretPosition), raw.count)
        let preview = ZhuyinLayout.display(result.commitPreview.isEmpty ? result.rawInput : result.commitPreview)
        let after = ZhuyinLayout.display(String(decoding: raw[caret...], as: UTF8.self))
        result.preedit = preview
        result.cursorUTF16 = max(0, preview.utf16.count - after.utf16.count)
        if !zhuyinListOpen {
            result.candidates = []; result.candidateIndices = []
            result.highlighted = 0; result.page = 0; result.isLastPage = true
        }
    }
    public func choose(_ index: Int) {
        let current = composition
        guard current.candidateIndices.indices.contains(index) else { return }
        let absolute = current.candidateIndices[index]
        if absolute == -1 { finishRaw(); return }
        invalidateRanking(); rankingLocked = false
        _ = rime.selectAbsolute(absolute); expandedKey = ""; publish(selectFirst: true)
    }
    public func page(backward: Bool) {
        lockRanking()
        let before = composition
        if before.isContinuous {
            let row = max(0, numberedRowStart + (backward ? -expandedColumns : expandedColumns))
            let column = options().keepCandidateSelectionOnPage ? before.highlighted % expandedColumns : 0
            moveExpandedSelection(to: row + column)
            return
        }
        guard backward ? before.page > 0 : !before.isLastPage else { publish(); return }
        let previous = before.page
        _ = rime.process(key: backward ? RimeKey.pageUp : RimeKey.pageDown)
        let after = composition
        if after.page != previous, !after.candidateIndices.isEmpty {
            // Preserve the displayed slot, not Rime's internal offset: the two
            // differ after model ranking or exact/fuzzy spelling prioritization.
            let slot = options().keepCandidateSelectionOnPage ? min(before.highlighted, after.candidateIndices.count - 1) : 0
            _ = rime.highlightAbsolute(after.candidateIndices[slot])
        }
        publish()
    }
    private func moveExpandedSelection(to destination: Int) {
        let desired = max(0, destination)
        while desired >= expandedItems.count && expandedHasMore { appendCandidates() }
        let next = composition
        let slot = min(desired, max(0, next.candidates.count - 1))
        if next.candidateIndices.indices.contains(slot) {
            _ = rime.highlightAbsolute(next.candidateIndices[slot])
            numberedRowStart = (slot / expandedColumns) * expandedColumns
        }
        publish()
    }
    public func cancel() { shift.cancel(); invalidateRanking(); rankingLocked = false; rime.clear(); expandedKey = ""; expandedItems = []; publish() }
    public func finish() { shift.cancel(); lockRanking(); if composition.isComposing { rime.commit() }; publish() }
    public func finishRaw() {
        shift.cancel()
        resetContext()
        if composition.isComposing {
            let raw = composition.rawInput
            rime.clear()
            onCommit?(raw)
        }
        publish()
    }
    public func toggleLanguage() { selectMode(nextMode) }
    public func selectMode(_ next: InputMode) {
        guard options().modes.contains(next), next != mode else { return }
        if next == .english || mode == .english { finishRaw() }
        else { resetContext() }
        mode = next
        applyOptions(preservingComposition: next.isChinese)
        applyScript()
        expandedKey = ""; expandedItems = []
        publish(selectFirst: true)
    }
    public func publish(selectFirst: Bool = false) {
        if let text = rime.takeCommit(), !text.isEmpty {
            expandedKey = ""
            if options().neuralRanking && !IsSecureEventInputEnabled() { recentContext = String((recentContext + text).suffix(24)) }
            onCommit?(outputText(text))
        }
        let isComposing = rime.composition.isComposing
        let ended = wasComposing && !isComposing
        wasComposing = isComposing
        if ended && options().expandedCandidates { onExpansionChange?(false) }
        if selectFirst, composition.highlighted != 0, let first = composition.candidateIndices.first, first >= 0 {
            _ = rime.highlightAbsolute(first)
        }
        onUpdate?(composition)
        requestRanking()
    }
    /// Called on client/caret changes. Context never crosses an input session.
    public func resetContext() { recentContext = ""; invalidateRanking(); rankingLocked = false }
    public func lockRanking() { rankingLocked = true; rankingGeneration += 1; rankingTicket?.cancel(); rankingTicket = nil }
    private func resetContextForEditingKey(_ key: Int32) {
        if [RimeKey.left, RimeKey.right, RimeKey.up, RimeKey.down, RimeKey.home, RimeKey.end, RimeKey.backspace, RimeKey.delete, RimeKey.enter].contains(key) { resetContext() }
    }
    private func invalidateRanking() { rankingGeneration += 1; rankingTicket?.cancel(); rankingTicket = nil; rankingKey = ""; rankingOrder = nil }
    private func key(for value: Composition) -> String {
        value.rawInput + "\u{0}" + value.preedit + "\u{0}" + String(value.isContinuous ? 0 : value.page) + "\u{0}" + value.candidates.prefix(7).map(\.text).joined(separator: "\u{1}")
    }
    private func requestRanking() {
        let current = baseComposition
        guard keyboard == .pinyin, options().neuralRanking, let ranker, !rankingLocked, !IsSecureEventInputEnabled(), recentContext.count >= 2,
              current.isComposing, rime.caretPosition == current.rawInput.utf8.count,
              !current.isContinuous, current.page == 0, current.candidates.count >= 2 else { return }
        let fingerprint = key(for: current)
        guard rankingKey != fingerprint else { return }
        invalidateRanking(); rankingKey = fingerprint
        let generation = rankingGeneration, start = rankingClock()
        let candidates = Array(current.candidates.prefix(7))
        // Give a new keystroke a chance to supersede this request before doing work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self, self.rankingGeneration == generation else { return }
            self.rankingTicket = ranker.rank(context: self.recentContext, candidates: candidates) { [weak self] order in
                guard let self, self.rankingGeneration == generation, self.options().neuralRanking, !self.rankingLocked,
                      !IsSecureEventInputEnabled(), self.key(for: self.baseComposition) == fingerprint,
                      self.rankingClock() - start <= 0.080,
                      let order, order.sorted() == Array(candidates.indices) else { return }
                let constrained = self.appliedOptions.fuzzyPinyinMask == 0 && !self.appliedOptions.autoCorrection ? order : PinyinCandidateOrder.prioritizeExact(candidates, preedit: current.preedit, cursorUTF16: current.cursorUTF16, order: order)
                (ranker as? CoreMLCandidateRanker)?.recordApplied()
                self.rankingOrder = constrained
                if let first = constrained.first, self.baseComposition.candidateIndices.indices.contains(first) {
                    _ = self.rime.highlightAbsolute(self.baseComposition.candidateIndices[first])
                }
                self.onUpdate?(self.composition)
            }
        }
    }
    deinit { rankingTicket?.cancel() }
    private func outputText(_ text: String) -> String {
        guard isChinese && !options().halfWidth else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.value == 0x20 ? UnicodeScalar(0x3000)! : (0x21...0x7e).contains(scalar.value) ? UnicodeScalar(scalar.value + 0xfee0)! : scalar
        }))
    }
}
