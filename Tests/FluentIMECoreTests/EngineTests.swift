import XCTest
import AppKit
@testable import FluentIMECore

final class EngineTests: XCTestCase {
    private static var engine: RimeEngine!
    private static var scratch: URL!

    override class func setUp() {
        super.setUp()
        do {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIMETests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let shared = scratch.appendingPathComponent("shared")
            if let precompiled = ProcessInfo.processInfo.environment["FLUENTIME_TEST_PRECOMPILED_DIR"] {
                try FileManager.default.copyItem(at: URL(fileURLWithPath: precompiled), to: shared)
                if FileManager.default.fileExists(atPath: shared.appendingPathComponent("build/fluent_pinyin.table.bin").path) {
                    let previousCache = scratch.appendingPathComponent("user/build")
                    try FileManager.default.createDirectory(at: previousCache, withIntermediateDirectories: true)
                    try Data("previous-release-prism".utf8).write(to: previousCache.appendingPathComponent("fluent_pinyin_a1.prism.bin"))
                }
                engine = try RimeEngine(sharedDirectory: shared, userDirectory: scratch.appendingPathComponent("user"))
            } else {
                try FileManager.default.copyItem(at: root.appendingPathComponent("Resources/Rime"), to: shared)
                try FileManager.default.copyItem(at: root.appendingPathComponent("Vendor/rime-pinyin-simp/pinyin_simp.dict.yaml"), to: shared.appendingPathComponent("pinyin_simp.dict.yaml"))
                engine = try RimeEngine(sharedDirectory: shared, userDirectory: scratch.appendingPathComponent("user"), fullCheck: true)
            }
        } catch { XCTFail("Cannot prepare real engine: \(error)") }
    }
    override class func tearDown() {
        engine = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }
    private func session(_ text: String = "") throws -> RimeSession {
        let engine = try XCTUnwrap(Self.engine)
        let session = try engine.makeSession()
        for byte in text.utf8 { XCTAssertTrue(session.process(key: Int32(byte))) }
        return session
    }

    func testSwitchingChineseModesPreservesCompositionWithDifferentLanguageRules() throws {
        let base = InputOptions(learning: false)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { base }, languageOptions: { mode in
            var options = base; options.autoCorrection = mode == .simplifiedChinese
            options.abbreviation = mode == .traditionalChinese; return options
        })
        var committed = ""; input.onCommit = { committed += $0 }
        for c in "nihao" { _ = input.handle(key(String(c))) }
        input.selectMode(.traditionalChinese)
        XCTAssertEqual(input.composition.rawInput, "nihao"); XCTAssertEqual(committed, "")
        XCTAssertEqual(input.mode, .traditionalChinese)
        input.selectMode(.simplifiedChinese)
        XCTAssertEqual(input.composition.rawInput, "nihao"); XCTAssertEqual(committed, "")
        input.selectMode(.english)
        XCTAssertEqual(committed, "nihao"); XCTAssertFalse(input.composition.isComposing)
    }

    func testSingleInitialsOfferCommonAbbreviations() throws {
        for (raw, expected) in [("m", "吗"), ("n", "你"), ("l", "了")] {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(autoCorrection: true, abbreviation: true, learning: false) })
            for c in raw { _ = input.handle(key(String(c))) }
            XCTAssertTrue(input.composition.candidates.contains { $0.text == expected }, "\(raw): \(input.composition.candidates.map(\.text))")
            XCTAssertEqual(input.composition.highlighted, 0)
        }
    }
    func testExactAbbreviationPrecedesFuzzyInitials() {
        let words = [Candidate("发现", comment: "fa xian"), Candidate("好像", comment: "hao xiang"), Candidate("或许", comment: "huo xu")]
        XCTAssertEqual(PinyinCandidateOrder.prioritizeExact(words, preedit: "h x", cursorUTF16: 3), [1, 2, 0])
    }

    func testPreviousCacheCannotOverrideBundledDictionary() throws {
        let previous = Self.scratch.appendingPathComponent("user/build/fluent_pinyin_a1.prism.bin")
        guard FileManager.default.fileExists(atPath: previous.path) else { throw XCTSkip("Requires bundled precompiled data") }
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
        for c in "nihao" { _ = input.handle(key(String(c))) }
        XCTAssertEqual(input.composition.candidates.first?.text, "你好")
        XCTAssertEqual(try Data(contentsOf: previous), Data("previous-release-prism".utf8), "Keep previous caches recoverable; do not delete user data")
    }

    func testRawFallbackCanBeCommittedByNumberSpaceAndClick() throws {
        for method in ["1", "space", "click"] {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
            var output = ""; input.onCommit = { output += $0 }
            _ = input.handle(key("u"))
            XCTAssertEqual(input.composition.candidates.first?.text, "u")
            if method == "click" { input.choose(0) }
            else { _ = input.handle(key(method == "1" ? "1" : " ", code: method == "1" ? 18 : 49)) }
            XCTAssertEqual(output, "u"); XCTAssertFalse(input.composition.isComposing)
        }
    }
    func testBracketExpansionPagesAndCollapsesOnlyAtFirstRow() throws {
        var options = InputOptions(learning: false, bracketsExpandCandidates: true)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        input.onExpansionChange = { [weak input] in options.expandedCandidates = $0; input?.applyOptions() }
        for c in "shi" { _ = input.handle(key(String(c))) }
        XCTAssertFalse(input.composition.isContinuous)
        _ = input.handle(key("]", code: 30))
        XCTAssertTrue(input.composition.isContinuous)
        _ = input.handle(key("]", code: 30))
        XCTAssertGreaterThanOrEqual(input.composition.highlighted, 30)
        input.setCandidateViewport(start: 6, columns: 6)
        _ = input.handle(key("[", code: 33))
        XCTAssertTrue(input.composition.isContinuous)
        XCTAssertEqual(input.composition.highlighted, 0)
        input.setCandidateViewport(start: 0, columns: 6)
        _ = input.handle(key("[", code: 33))
        XCTAssertFalse(input.composition.isContinuous)
        input.cancel()
        var output = ""; input.onCommit = { output += $0 }
        _ = input.handle(key("]", code: 30)); input.finish()
        XCTAssertEqual(output, "】")
    }
    func testWanxiangWordsAndGrammarWithDefaultAndAllFuzzyRules() throws {
        XCTAssertTrue(try XCTUnwrap(Self.engine).grammarAvailable)
        for mask in [0, FuzzyPinyinRule.inIng.rawValue, FuzzyPinyinRule.validMask] {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(autoCorrection: true, learning: false, fuzzyPinyinMask: mask, wanxiangGrammar: true) })
            for (spelling, expected) in [("fashenjing", "发神经"), ("rengongzhineng", "人工智能"), ("jintiantianqibucuo", "今天天气不错")] {
                input.cancel(); for c in spelling { _ = input.handle(key(String(c))) }
                XCTAssertEqual(input.composition.candidates.first?.text, expected, "mask=\(mask), \(spelling)")
            }
            if mask != 0 {
                input.cancel(); for c in "fashenjin" { _ = input.handle(key(String(c))) }
                XCTAssertEqual(input.composition.candidates.first?.text, "发神经", "mask=\(mask)")
            }
        }
    }

    func testFullPinyinAndSpaceCommit() throws {
        let input = try session("nihao")
        XCTAssertEqual(input.composition.candidates.first?.text, "你好")
        XCTAssertTrue(input.process(key: 32))
        XCTAssertEqual(input.takeCommit(), "你好")
        XCTAssertNil(input.takeCommit())
        XCTAssertFalse(input.composition.isComposing)
    }

    func testSentencesAndAbbreviation() throws {
        for text in ["zhongguo", "shijie", "woaini", "nh"] {
            let input = try session(text)
            XCTAssertFalse(input.composition.candidates.isEmpty, text)
            XCTAssertTrue(input.select(0))
            XCTAssertFalse((input.takeCommit() ?? "").isEmpty, text)
        }
    }

    func testPagingAndSelectionFromCurrentPage() throws {
        let input = try session("shi")
        let firstPage = input.composition.candidates
        XCTAssertEqual(firstPage.count, 7)
        XCTAssertFalse(input.composition.isLastPage)
        XCTAssertTrue(input.process(key: RimeKey.pageDown))
        XCTAssertEqual(input.composition.page, 1)
        XCTAssertNotEqual(input.composition.candidates, firstPage)
        let expected = input.composition.candidates[1].text
        XCTAssertTrue(input.select(1))
        XCTAssertEqual(input.takeCommit(), expected)
    }

    func testNumericSelectionAndArrowNavigation() throws {
        let input = try session("shi")
        let expected = input.composition.candidates[2].text
        XCTAssertTrue(input.process(key: 51)) // '3'
        XCTAssertEqual(input.takeCommit(), expected)
        for byte in "nihao".utf8 { input.process(key: Int32(byte)) }
        XCTAssertTrue(input.process(key: RimeKey.down))
        XCTAssertEqual(input.composition.highlighted, 1)
    }

    func testHorizontalArrowsCrossRightPageAndEnterPinyinFromFirstCandidate() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
        var committed = ""
        input.onCommit = { committed += $0 }
        XCTAssertFalse(input.handle(key("", code: 124)), "No menu: let the application handle Right")
        for character in "shi" { _ = input.handle(key(String(character))) }
        let original = input.composition
        for index in 1...7 {
            XCTAssertTrue(input.handle(key("", code: 124)))
            XCTAssertEqual(input.composition.page, index / 7)
            XCTAssertEqual(input.composition.highlighted, index % 7)
            XCTAssertEqual(input.composition.rawInput, original.rawInput)
            XCTAssertEqual(input.composition.cursorUTF16, original.cursorUTF16)
        }
        XCTAssertTrue(input.handle(key("", code: 123)))
        XCTAssertEqual(input.composition.page, 0)
        XCTAssertEqual(input.rime.caretPosition, 0)
        for _ in 0..<3 { _ = input.handle(key("", code: 124)) }
        XCTAssertEqual(input.rime.caretPosition, 3)
        _ = input.handle(key("", code: 124))
        XCTAssertEqual(input.composition.highlighted, 1)
        let expected = input.composition.candidates[1].text
        XCTAssertTrue(input.handle(key(" ", code: 49)))
        XCTAssertEqual(committed, expected)
        XCTAssertFalse(input.handle(key("", code: 123)))
        input.toggleLanguage()
        XCTAssertFalse(input.handle(key("", code: 124)))
    }

    func testEveryFuzzyRuleChangesConversionAndCanBeTurnedOff() throws {
        let examples: [(FuzzyPinyinRule, String, String)] = [
            (.zZh, "zongguo", "中国"), (.cCh, "cifan", "吃饭"), (.sSh, "sijie", "世界"),
            (.nL, "lihao", "你好"), (.fH, "fao", "好"), (.anAng, "guanchang", "广场"),
            (.enEng, "fenzheng", "风筝"), (.inIng, "jincha", "警察")
        ]
        for (rule, spelling, expected) in examples {
            var options = InputOptions(autoCorrection: false, abbreviation: false, learning: false)
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
            func containsExpected() -> Bool {
                for character in spelling { _ = input.handle(key(String(character))) }
                for _ in 0..<30 {
                    if input.composition.candidates.contains(where: { $0.text == expected }) { return true }
                    if input.composition.isLastPage { break }
                    input.page(backward: false)
                }
                return false
            }
            XCTAssertFalse(containsExpected(), "Disabled \(rule.title)")
            input.cancel()
            options.fuzzyPinyinMask = rule.rawValue
            input.applyOptions()
            XCTAssertTrue(containsExpected(), "Enabled \(rule.title): \(spelling) → \(expected)")
            input.cancel()
            options.fuzzyPinyinMask = 0
            input.applyOptions()
            XCTAssertFalse(containsExpected(), "Turned off \(rule.title)")
            input.cancel()
        }
    }

    func testAllFuzzyCombinationsLoadWithExistingPreferences() throws {
        for mask in 0...FuzzyPinyinRule.validMask {
            for abbreviation in [false, true] {
                for correction in [false, true] {
                    for learning in [false, true] {
                        let options = InputOptions(autoCorrection: correction, abbreviation: abbreviation, learning: learning, fuzzyPinyinMask: mask)
                        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
                        for character in "nihao" { _ = input.handle(key(String(character))) }
                        XCTAssertTrue(input.composition.candidates.contains { $0.text == "你好" }, options.schemaID)
                    }
                }
            }
        }
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
            InputOptions(autoCorrection: false, abbreviation: false, learning: false, fuzzyPinyinMask: FuzzyPinyinRule.zZh.rawValue | FuzzyPinyinRule.nL.rawValue)
        })
        // The two enabled rules must both apply to separate syllables of the same phrase.
        for character in "laozong" { _ = input.handle(key(String(character))) }
        XCTAssertTrue(input.composition.candidates.contains { $0.text == "闹钟" })
    }

    func testNumberKeysSelectTheDisplayedPageAfterEveryPagingMethod() throws {
        let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26]
        for method in ["button", "]", "=", "PageDown"] {
            for number in 1...7 {
                let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
                var committed = ""
                input.onCommit = { committed += $0 }
                for character in "shi" { XCTAssertTrue(input.handle(key(String(character)))) }
                switch method {
                case "button": input.page(backward: false)
                case "]": XCTAssertTrue(input.handle(key("]", code: 30)))
                case "=": XCTAssertTrue(input.handle(key("=", code: 24)))
                default: XCTAssertTrue(input.handle(key("", code: 121)))
                }
                let displayed = input.composition
                XCTAssertEqual(displayed.page, 1, method)
                let expected = try XCTUnwrap(displayed.candidates.indices.contains(number - 1) ? displayed.candidates[number - 1].text : nil)
                XCTAssertTrue(input.handle(key(String(number), code: digitKeyCodes[number - 1])))
                XCTAssertEqual(committed, expected, "\(method), page 2, key \(number)")
                XCTAssertFalse(input.composition.isComposing)
            }
        }
    }

    func testRepeatedKeyboardPagingAndSpaceKeepTheDisplayedPage() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
        var committed = ""
        input.onCommit = { committed += $0 }
        for character in "shi" { _ = input.handle(key(String(character))) }
        for page in 1...3 {
            XCTAssertTrue(input.handle(key("]", code: 30)))
            XCTAssertEqual(input.composition.page, page)
        }
        XCTAssertTrue(input.handle(key("[", code: 33)))
        XCTAssertEqual(input.composition.page, 2)
        let displayed = input.composition
        let expected = try XCTUnwrap(displayed.candidates.first?.text)
        XCTAssertTrue(input.handle(key(" ", code: 49)))
        XCTAssertEqual(committed, expected)
    }

    func testPagingKeepsDisplayedSelectionAfterMovingSelection() throws {
        for method in ["button", "]", "=", "PageDown"] {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
            for char in "shi" { _ = input.handle(key(String(char))) }
            _ = input.handle(key("", code: 124))
            XCTAssertEqual(input.composition.highlighted, 1)
            switch method {
            case "button": input.page(backward: false)
            case "]": _ = input.handle(key("]", code: 30))
            case "=": _ = input.handle(key("=", code: 24))
            default: _ = input.handle(key("", code: 121))
            }
            XCTAssertEqual(input.composition.page, 1, method)
            XCTAssertEqual(input.composition.highlighted, 1, method)
            _ = input.handle(key("", code: 124))
            switch method {
            case "button": input.page(backward: true)
            case "]": _ = input.handle(key("[", code: 33))
            case "=": _ = input.handle(key("-", code: 27))
            default: _ = input.handle(key("", code: 116))
            }
            XCTAssertEqual(input.composition.page, 0, method)
            XCTAssertEqual(input.composition.highlighted, 2, method)
            var output = ""; input.onCommit = { output += $0 }
            let expected = input.composition.candidates[2].text
            _ = input.handle(key(" ", code: 49))
            XCTAssertEqual(output, expected, method)
        }
    }

    func testPagingAtBoundaryDoesNotChangeSelection() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
        for char in "shi" { _ = input.handle(key(String(char))) }
        _ = input.handle(key("", code: 124))
        let before = input.composition
        input.page(backward: true)
        XCTAssertEqual(input.composition, before)
    }

    func testPagingSelectionPreferenceChangesWithoutResettingComposition() throws {
        for method in ["button", "]", "=", "PageDown"] {
            var keepSelection = false
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
                InputOptions(learning: false, keepCandidateSelectionOnPage: keepSelection)
            })
            for char in "shi" { _ = input.handle(key(String(char))) }
            func nextPage() {
                switch method {
                case "button": input.page(backward: false)
                case "]": _ = input.handle(key("]", code: 30))
                case "=": _ = input.handle(key("=", code: 24))
                default: _ = input.handle(key("", code: 121))
                }
            }
            _ = input.handle(key("", code: 124))
            nextPage()
            XCTAssertEqual(input.composition.highlighted, 0, method)
            keepSelection = true
            _ = input.handle(key("", code: 124))
            nextPage()
            XCTAssertEqual(input.composition.highlighted, 1, method)
            keepSelection = false
            nextPage()
            XCTAssertEqual(input.composition.highlighted, 0, method)
            XCTAssertEqual(input.composition.rawInput, "shi")
            XCTAssertEqual(input.composition.page, 3)
        }
    }

    func testExactNePrecedesNLFuzzyLeWithoutRemovingFuzzyCandidates() throws {
        for mask in [FuzzyPinyinRule.nL.rawValue, FuzzyPinyinRule.validMask] {
            for expanded in [false, true] {
                for action in ["1", "space", "click", "second"] {
                    let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
                        InputOptions(autoCorrection: true, learning: false, fuzzyPinyinMask: mask, expandedCandidates: expanded, wanxiangGrammar: true)
                    })
                    for char in "ne" { _ = input.handle(key(String(char))) }
                    let displayed = input.composition
                    XCTAssertEqual(displayed.candidates.first?.text, "呢")
                    XCTAssertEqual(displayed.highlighted, 0)
                    XCTAssertTrue(displayed.candidates.contains { $0.text == "了" })
                    var output = ""; input.onCommit = { output += $0 }
                    switch action {
                    case "1": _ = input.handle(key("1"))
                    case "space": _ = input.handle(key(" ", code: 49))
                    case "click": input.choose(0)
                    default: _ = input.handle(key("", code: 124)); _ = input.handle(key(" ", code: 49))
                    }
                    XCTAssertEqual(output, displayed.candidates[action == "second" ? 1 : 0].text)
                }
            }
        }
    }

    func testPagingFromExactMatchUsesDisplayedSlotInsteadOfRimeOffset() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
            InputOptions(learning: false, fuzzyPinyinMask: FuzzyPinyinRule.nL.rawValue)
        })
        for char in "ne" { _ = input.handle(key(String(char))) }
        XCTAssertEqual(input.composition.highlighted, 0)
        XCTAssertEqual(input.rime.composition.highlighted, 1)
        for slot in 0...1 {
            if slot > 0 { _ = input.handle(key("", code: 124)) }
            input.page(backward: false)
            XCTAssertEqual(input.composition.page, 1)
            XCTAssertEqual(input.composition.highlighted, slot)
            input.page(backward: true)
            XCTAssertEqual(input.composition.page, 0)
            XCTAssertEqual(input.composition.highlighted, slot)
        }
    }

    func testSeventhCandidateSelection() throws {
        let input = try session("shi")
        let expected = input.composition.candidates[6].text
        XCTAssertTrue(input.process(key: 55)) // '7'
        XCTAssertEqual(input.takeCommit(), expected)
    }

    func testBracketKeysPageCandidatesAndKeepStandalonePunctuation() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine))
        for character in "shi" { _ = input.handle(key(String(character))) }
        let first = input.composition.candidates
        XCTAssertTrue(input.handle(key("]", code: 30)))
        XCTAssertEqual(input.composition.page, 1)
        XCTAssertNotEqual(input.composition.candidates, first)
        XCTAssertTrue(input.handle(key("[", code: 33)))
        XCTAssertEqual(input.composition.page, 0)
        XCTAssertEqual(input.composition.candidates, first)
        input.cancel()
        var committed = ""
        input.onCommit = { committed += $0 }
        XCTAssertTrue(input.handle(key("]", code: 30)))
        input.finish()
        XCTAssertEqual(committed, "】")
    }

    func testInlineEmojiUsesRealDictionaryAndCommits() throws {
        let input = try session("she")
        let index = try XCTUnwrap(input.composition.candidates.firstIndex(where: { $0.text == "🐍" }))
        XCTAssertTrue(input.select(index))
        XCTAssertEqual(input.takeCommit(), "🐍")
        XCTAssertFalse(input.composition.isComposing)
    }

    func testCoolAndKaomojiAreRealSelectableCandidates() throws {
        for expected in ["🆒", "/(ㄒoㄒ)/~~"] {
            let input = try session("ku")
            let index = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == expected })
            XCTAssertTrue(input.select(index))
            XCTAssertEqual(input.takeCommit(), expected)
        }
    }

    func testBackspaceEscapeAndNoEmptySpaceCapture() throws {
        let input = try session("nihao")
        XCTAssertTrue(input.process(key: RimeKey.backspace))
        XCTAssertEqual(input.composition.rawInput, "niha")
        XCTAssertTrue(input.process(key: RimeKey.escape))
        XCTAssertFalse(input.composition.isComposing)
        XCTAssertNil(input.takeCommit())
        XCTAssertFalse(input.process(key: 32))
    }

    func testPunctuationOption() throws {
        let input = try session()
        XCTAssertTrue(input.process(key: 44))
        XCTAssertEqual(input.takeCommit(), "，")
        input.setOption("ascii_punct", true)
        let consumed = input.process(key: 44)
        if consumed { XCTAssertEqual(input.takeCommit(), ",") }
        else { XCTAssertNil(input.takeCommit()) }
    }

    func testPunctuationPreferenceAppliesInitiallyAndAfterChanges() throws {
        var options = InputOptions(englishPunctuation: true, learning: false)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        var committed = ""
        input.onCommit = { committed += $0 }
        func checkComma(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
            committed = ""
            // An unhandled ASCII comma is inserted by the host application.
            let handled = input.handle(key(",", code: 43))
            XCTAssertEqual(handled ? committed : ",", expected, file: file, line: line)
        }
        checkComma(",")
        options.englishPunctuation = false
        input.applyOptions()
        checkComma("，")
        options.englishPunctuation = true
        input.applyOptions()
        checkComma(",")
        options.autoCorrection = true
        input.applyOptions()
        checkComma(",")
    }

    func testClientSessionsAreIsolated() throws {
        let first = try session("nihao")
        let second = try session("zhongguo")
        XCTAssertEqual(first.composition.rawInput, "nihao")
        XCTAssertEqual(second.composition.rawInput, "zhongguo")
        first.clear()
        XCTAssertTrue(second.composition.isComposing)
    }

    func testInvalidCandidateDoesNotChangeComposition() throws {
        let input = try session("nihao")
        let original = input.composition
        XCTAssertFalse(input.select(-1)); XCTAssertFalse(input.select(9))
        XCTAssertEqual(original, input.composition)
    }

    private func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testReturnCommitsRawPinyinAndApplicationShortcutPassesThrough() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine))
        var committed = ""
        input.onCommit = { committed += $0 }
        for character in "nihao" { XCTAssertTrue(input.handle(key(String(character)))) }
        XCTAssertTrue(input.handle(key("\r", code: 36)))
        XCTAssertEqual(committed, "nihao")
        XCTAssertFalse(input.composition.isComposing)
        committed = ""
        for character in "nihao" { _ = input.handle(key(String(character))) }
        XCTAssertFalse(input.handle(key("c", flags: .command)))
        XCTAssertEqual(committed, "你好")
        XCTAssertFalse(input.composition.isComposing)
    }

    func testShiftLanguageToggleAndEnglishPassthrough() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(enabledModes: [.simplifiedChinese, .english]) })
        XCTAssertFalse(input.handle(key("", code: 56, flags: .shift, type: .flagsChanged)))
        XCTAssertTrue(input.handle(key("", code: 56, type: .flagsChanged)))
        XCTAssertFalse(input.isChinese)
        XCTAssertFalse(input.handle(key("a")))
        XCTAssertFalse(input.composition.isComposing)
        _ = input.handle(key("", code: 56, flags: .shift, type: .flagsChanged))
        _ = input.handle(key("", code: 56, type: .flagsChanged))
        XCTAssertTrue(input.isChinese)
        XCTAssertTrue(input.handle(key("n")))
    }

    func testSwitchingToEnglishFinalizesRawSpellingExactlyOnce() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine))
        var commits: [String] = []
        input.onCommit = { commits.append($0) }
        for character in "jiux" { _ = input.handle(key(String(character))) }
        XCTAssertTrue(input.composition.isComposing)
        input.selectMode(.english)
        XCTAssertEqual(commits, ["jiux"])
        XCTAssertFalse(input.composition.isComposing)
        XCTAssertFalse(input.isChinese)
        input.finishRaw()
        XCTAssertEqual(commits, ["jiux"])
    }

    func testShiftCyclesEveryEnabledModeAndPreservesChineseComposition() throws {
        for mask in 1..<8 {
            let modes = InputMode.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false, enabledModes: modes, defaultMode: modes[0]) })
            for index in 1...(modes.count * 2) {
                _ = input.handle(key("", code: 56, flags: .shift, type: .flagsChanged))
                _ = input.handle(key("", code: 56, type: .flagsChanged))
                XCTAssertEqual(input.mode, modes[index % modes.count])
            }
        }
        let input = try InputSession(engine: XCTUnwrap(Self.engine))
        var commits: [String] = []; input.onCommit = { commits.append($0) }
        for character in "nihao" { _ = input.handle(key(String(character))) }
        input.toggleLanguage()
        XCTAssertEqual(input.mode, .traditionalChinese)
        XCTAssertEqual(input.composition.rawInput, "nihao"); XCTAssertTrue(commits.isEmpty)
        input.toggleLanguage()
        XCTAssertEqual(input.mode, .english); XCTAssertEqual(commits, ["nihao"])
    }

    func testNativeCapsLockFinalizesRawAndPassesUppercaseThrough() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine))
        var committed = ""
        input.onCommit = { committed += $0 }
        for character in "nihao" { _ = input.handle(key(String(character))) }
        XCTAssertFalse(input.handle(key("", code: 57, flags: .capsLock, type: .flagsChanged)))
        XCTAssertEqual(committed, "nihao")
        XCTAssertFalse(input.composition.isComposing)
        XCTAssertFalse(input.handle(key("A", flags: .capsLock)))
        XCTAssertEqual(committed, "nihao")
        XCTAssertTrue(input.isChinese) // The system owns Caps Lock, not a second internal toggle.
    }

    func testLivePunctuationPreferenceAndDisabledShiftSwitch() throws {
        var options = InputOptions(shiftSwitch: false)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        var committed = ""
        input.onCommit = { committed += $0 }
        _ = input.handle(key(","))
        XCTAssertEqual(committed, "，")
        options.englishPunctuation = true
        committed = ""
        let consumed = input.handle(key(","))
        XCTAssertTrue((consumed && committed == ",") || (!consumed && committed.isEmpty))
        _ = input.handle(key("", code: 56, flags: .shift, type: .flagsChanged))
        _ = input.handle(key("", code: 56, type: .flagsChanged))
        XCTAssertTrue(input.isChinese)
    }

    func testAllSettingsSchemasLoadAndConvert() throws {
        for abbreviation in [false, true] {
            for correction in [false, true] {
                for learning in [false, true] {
                    let options = InputOptions(autoCorrection: correction, abbreviation: abbreviation, learning: learning)
                    let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
                    for character in "nihao" { _ = input.handle(key(String(character))) }
                    XCTAssertTrue(input.composition.candidates.contains { $0.text == "你好" }, options.schemaID)
                }
            }
        }
    }

    func testAbbreviationPreferenceChangesRealCandidates() throws {
        var options = InputOptions()
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        for character in "nh" { _ = input.handle(key(String(character))) }
        XCTAssertTrue(input.composition.candidates.contains { $0.text == "你好" })
        input.cancel(); options.abbreviation = false
        for character in "nh" { _ = input.handle(key(String(character))) }
        XCTAssertFalse(input.composition.candidates.contains { $0.text == "你好" })
    }

    func testTraditionalModeConvertsCandidatesAndCommitsWithoutChangingSpelling() throws {
        var options = InputOptions(learning: false)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        for c in "hanyu" { _ = input.handle(key(String(c))) }
        XCTAssertTrue(input.composition.candidates.contains { $0.text == "汉语" })
        input.selectMode(.traditionalChinese)
        XCTAssertEqual(input.composition.rawInput, "hanyu")
        let index = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == "漢語" })
        var output = ""; input.onCommit = { output += $0 }; input.choose(index)
        XCTAssertEqual(output, "漢語")
        input.toggleLanguage(); XCTAssertEqual(input.mode, .english)
        input.toggleLanguage(); XCTAssertEqual(input.mode, .simplifiedChinese)
        options.enabledModes = [.simplifiedChinese, .english]; input.applyOptions()
        XCTAssertEqual(input.mode, .simplifiedChinese)
        input.selectMode(.traditionalChinese); XCTAssertEqual(input.mode, .simplifiedChinese)
        options.enabledModes = [.traditionalChinese]; input.applyOptions()
        XCTAssertEqual(input.mode, .traditionalChinese)
        input.toggleLanguage(); XCTAssertEqual(input.mode, .traditionalChinese)
    }

    func testExpansionEndsWithCompositionButSurvivesPartialCandidateSelection() throws {
        var options = InputOptions(learning: false)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        input.onExpansionChange = { options.expandedCandidates = $0 }
        for ending in ["commit", "cancel", "english"] {
            input.selectMode(.simplifiedChinese)
            for c in "nihao" { _ = input.handle(key(String(c))) }
            options.expandedCandidates = true; input.publish()
            XCTAssertTrue(input.composition.isContinuous)
            if ending == "commit" { input.choose(0) }
            else if ending == "cancel" { input.cancel() }
            else { input.selectMode(.english) }
            XCTAssertFalse(options.expandedCandidates, ending)
        }
        input.selectMode(.simplifiedChinese)
        for c in "nihao" { _ = input.handle(key(String(c))) }
        options.expandedCandidates = true; input.publish()
        let prefix = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == "你" })
        input.choose(prefix)
        XCTAssertTrue(input.composition.isComposing); XCTAssertTrue(options.expandedCandidates)
        input.cancel(); XCTAssertFalse(options.expandedCandidates)
    }

    func testCorrectionCannotReplaceValidDeiSentence() throws {
        for mask in [0, FuzzyPinyinRule.validMask] {
            for grammar in [false, true] {
                let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
                    InputOptions(autoCorrection: true, learning: false, fuzzyPinyinMask: mask, wanxiangGrammar: grammar)
                })
                for (spelling, expected) in [("nideirang", "你得让"), ("ni'dei'rang", "你得让"), ("nidei", "你得")] {
                    input.cancel()
                    for c in spelling { _ = input.handle(key(String(c))) }
                    XCTAssertEqual(input.composition.candidates.first?.text, expected, "\(spelling), fuzzy=\(mask), grammar=\(grammar)")
                    XCTAssertEqual(input.composition.highlighted, 0)
                    var commit = ""; input.onCommit = { commit += $0 }
                    _ = input.handle(key(" ", code: 49))
                    XCTAssertEqual(commit, expected)
                }
            }
        }
    }

    func testCLDREmojiCandidatesSurviveExpansionPagingAndSelection() throws {
        for expanded in [false, true] {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
                InputOptions(autoCorrection: true, learning: false, fuzzyPinyinMask: FuzzyPinyinRule.validMask,
                             expandedCandidates: expanded, wanxiangGrammar: true)
            })
            for (spelling, emoji) in [("fenbian", "💩"), ("nihao", "👋"), ("zhangyu", "🐙"), ("jiqiren", "🤖"), ("she", "🐍")] {
                input.cancel()
                for c in spelling { _ = input.handle(key(String(c))) }
                let index = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == emoji }, spelling)
                XCTAssertLessThan(index, 7, "Visible in the first row/page: \(spelling)")
                XCTAssertEqual(input.composition.candidates.filter { $0.text == emoji }.count, 1)
                var commit = ""; input.onCommit = { commit += $0 }
                input.choose(index)
                XCTAssertEqual(commit, emoji); XCTAssertFalse(input.composition.isComposing)
            }
            for c in "fenbian" { _ = input.handle(key(String(c))) }
            input.page(backward: false); input.page(backward: true)
            let index = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == "💩" })
            var commit = ""; input.onCommit = { commit += $0 }
            input.choose(index); XCTAssertEqual(commit, "💩")
        }
    }

    func testEmojiFilterDoesNotReplaceWordsInsideSentences() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false, wanxiangGrammar: true) })
        for c in "woxihuanni" { _ = input.handle(key(String(c))) }
        XCTAssertEqual(input.composition.candidates.first?.text, "我喜欢你")
    }

    func testCorrectionFindsAdjacentKeyTypo() throws {
        var options = InputOptions(autoCorrection: true)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        for character in "zhonhguo" { _ = input.handle(key(String(character))) }
        XCTAssertTrue(input.composition.candidates.contains { $0.text == "中国" })
        input.cancel(); options.autoCorrection = false
        for character in "zhonhguo" { _ = input.handle(key(String(character))) }
        XCTAssertFalse(input.composition.candidates.contains { $0.text == "中国" })
    }

    func testDefaultModeChangesAndFullWidthCommit() throws {
        var options = InputOptions(startsInEnglish: true, halfWidth: false)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        var committed = ""
        input.onCommit = { committed += $0 }
        XCTAssertFalse(input.isChinese); XCTAssertFalse(input.handle(key("a")))
        options.startsInEnglish = false
        XCTAssertTrue(input.handle(key("1"))); XCTAssertEqual(committed, "１")
        committed = ""
        for character in "nihao" { _ = input.handle(key(String(character))) }
        _ = input.handle(key("\r", code: 36)); XCTAssertEqual(committed, "ｎｉｈａｏ")
        XCTAssertFalse(input.handle(key("c", flags: .command)))
        options.halfWidth = true; XCTAssertFalse(input.handle(key("1")))
    }
    func testContinuousIteratorMatchesPagesWithoutMovingSelection() throws {
        let input = try session("shi")
        let original = input.composition
        let first = input.candidates(from: 0, limit: 17)
        let second = input.candidates(from: 17, limit: 18)
        XCTAssertEqual(input.composition.page, original.page)
        XCTAssertEqual(input.composition.highlighted, original.highlighted)
        XCTAssertTrue(first.hasMore)
        var paged: [Candidate] = []
        for _ in 0..<5 { paged += input.composition.candidates; input.process(key: RimeKey.pageDown) }
        XCTAssertEqual(first.items + second.items, paged)
        XCTAssertTrue(input.candidates(from: -1).items.isEmpty)
    }

    func testExpandedScrollNumbersClickAndGridArrowsUseAbsoluteCandidates() throws {
        for action in 0..<3 {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false, expandedCandidates: true) })
            var output = ""; input.onCommit = { output += $0 }
            for char in "shi" { input.handle(key(String(char))) }
            let expanded = input.composition
            XCTAssertTrue(expanded.isContinuous); XCTAssertGreaterThan(expanded.candidates.count, 7)
            input.setCandidateViewport(start: 18, columns: 6)
            let selected: Int
            if action == 0 { selected = 19; input.handle(key("2")) }
            else if action == 1 { selected = 12; input.choose(12) }
            else {
                input.setCandidateViewport(start: 0, columns: 6)
                input.handle(key("", code: 125)); XCTAssertEqual(input.composition.highlighted, 6)
                input.handle(key("", code: 124)); XCTAssertEqual(input.composition.highlighted, 7)
                selected = 7; input.handle(key(" ", code: 49))
            }
            XCTAssertEqual(output, expanded.candidates[selected].text)
        }
    }

    func testExpandedLazyLoadingAndReturnToCollapsedPage() throws {
        var options = InputOptions(learning: false, expandedCandidates: true)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { options })
        for char in "shi" { input.handle(key(String(char))) }
        let before = input.composition
        input.loadMoreCandidates()
        let after = input.composition
        XCTAssertEqual(Array(after.candidates.prefix(before.candidates.count)), before.candidates)
        XCTAssertTrue(after.candidates.count > before.candidates.count || !after.hasMoreCandidates)
        XCTAssertEqual(after.highlighted, before.highlighted)
        _ = input.rime.highlightAbsolute(20)
        options.expandedCandidates = false; input.applyOptions()
        XCTAssertEqual(input.composition.candidateIndices.first, 14)
        XCTAssertEqual(input.composition.highlighted, 6)
    }

    private final class ManualRanker: CandidateReranking {
        var now: TimeInterval = 0
        var completion: (([Int]?) -> Void)?
        var requested: (() -> Void)?
        var context = ""
        var ticket: RankingTicket?
        func rank(context: String, candidates: [Candidate], completion: @escaping ([Int]?) -> Void) -> RankingTicket {
            self.context = context; self.completion = completion
            let ticket = RankingTicket(); self.ticket = ticket; requested?(); return ticket
        }
    }
    private func rankedInput(_ ranker: ManualRanker) throws -> InputSession {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false, neuralRanking: true) }, ranker: ranker, rankingClock: { ranker.now })
        for char in "nihao" { input.handle(key(String(char))) }
        input.handle(key(" ", code: 49))
        return input
    }
    func testNeuralOrderPreservesNumberSpaceAndArrowSelection() throws {
        for action in 0..<3 {
            let fake = ManualRanker(), requested = expectation(description: "model request")
            fake.requested = { requested.fulfill() }
            let input = try rankedInput(fake)
            var output = ""; input.onCommit = { output += $0 }
            for char in "shi" { input.handle(key(String(char))) }
            let original = input.composition.candidates
            wait(for: [requested], timeout: 1)
            XCTAssertEqual(fake.context, "你好")
            fake.now = 0.079 // On-time even when the CI runner is busy.
            fake.completion?(Array(original.indices.reversed()))
            XCTAssertEqual(input.composition.candidates.first, original.last)
            XCTAssertEqual(input.composition.highlighted, 0)
            if action == 0 { input.handle(key("1")) }
            else if action == 1 { input.handle(key(" ", code: 49)) }
            else { input.handle(key("", code: 124)); input.handle(key(" ", code: 49)) }
            XCTAssertEqual(output, original[original.count - (action == 2 ? 2 : 1)].text)
        }
    }
    func testPagingFromNeuralFirstCandidateResetsTheUnderlyingOffset() throws {
        let fake = ManualRanker(), requested = expectation(description: "model request")
        fake.requested = { requested.fulfill() }
        let input = try rankedInput(fake)
        for char in "shi" { _ = input.handle(key(String(char))) }
        wait(for: [requested], timeout: 1)
        let original = input.composition.candidates
        fake.completion?(Array(original.indices.reversed()))
        XCTAssertEqual(input.composition.highlighted, 0)
        XCTAssertEqual(input.rime.composition.highlighted, 6)
        _ = input.handle(key("]", code: 30))
        XCTAssertEqual(input.composition.page, 1)
        XCTAssertEqual(input.composition.highlighted, 0)
        _ = input.handle(key("[", code: 33))
        XCTAssertEqual(input.composition.page, 0)
        XCTAssertEqual(input.composition.highlighted, 0)
        XCTAssertEqual(input.composition.candidates.first, original.last)
        var output = ""; input.onCommit = { output += $0 }
        _ = input.handle(key(" ", code: 49))
        XCTAssertEqual(output, original.last?.text)
    }

    func testNeuralRankingCannotPromoteFuzzyLeAheadOfExactNe() throws {
        let fake = ManualRanker(), requested = expectation(description: "model request")
        fake.requested = { requested.fulfill() }
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: {
            InputOptions(learning: false, fuzzyPinyinMask: FuzzyPinyinRule.nL.rawValue, neuralRanking: true)
        }, ranker: fake, rankingClock: { fake.now })
        for char in "nihao" { _ = input.handle(key(String(char))) }
        _ = input.handle(key(" ", code: 49))
        for char in "ne" { _ = input.handle(key(String(char))) }
        wait(for: [requested], timeout: 1)
        fake.completion?(Array(input.composition.candidates.indices.reversed()))
        // Several valid ne readings (呢、讷、哪) can be reordered by the model;
        // none of the fuzzy le readings may overtake that exact-spelling tier.
        XCTAssertEqual(input.composition.candidates.first?.comment, "ne")
        let exact = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == "呢" })
        let fuzzy = try XCTUnwrap(input.composition.candidates.firstIndex { $0.text == "了" })
        XCTAssertLessThan(exact, fuzzy)
        XCTAssertEqual(input.composition.highlighted, 0)
    }

    func testSlowNeuralResultLeavesRimeCandidatesUnchanged() throws {
        let fake = ManualRanker(), requested = expectation(description: "model request")
        fake.requested = { requested.fulfill() }
        let input = try rankedInput(fake)
        for char in "shi" { _ = input.handle(key(String(char))) }
        wait(for: [requested], timeout: 1)
        let current = input.composition
        fake.now = 0.081
        fake.completion?(Array(current.candidates.indices.reversed()))
        XCTAssertEqual(input.composition.candidates, current.candidates)
        XCTAssertEqual(input.composition.highlighted, current.highlighted)
    }
    func testNewKeystrokeInvalidatesPendingNeuralOrder() throws {
        let fake = ManualRanker(), requested = expectation(description: "model request")
        fake.requested = { requested.fulfill() }
        let input = try rankedInput(fake)
        for char in "shi" { _ = input.handle(key(String(char))) }
        wait(for: [requested], timeout: 1)
        let completion = fake.completion, ticket = fake.ticket
        fake.requested = nil
        _ = input.handle(key("j")); let current = input.composition
        completion?(Array(0..<7).reversed().map { $0 })
        XCTAssertEqual(input.composition.candidates, current.candidates)
        XCTAssertTrue(ticket?.isCancelled == true)
        input.cancel()
    }
    func testStaleNeuralResultsAndClientContextAreDiscarded() throws {
        let fake = ManualRanker(), requested = expectation(description: "model request")
        fake.requested = { requested.fulfill() }
        let input = try rankedInput(fake)
        for char in "shi" { input.handle(key(String(char))) }
        wait(for: [requested], timeout: 1)
        let complete = fake.completion, oldTicket = fake.ticket
        input.resetContext()
        let original = input.composition.candidates
        complete?(Array(original.indices.reversed()))
        XCTAssertEqual(input.composition.candidates, original)
        XCTAssertTrue(oldTicket?.isCancelled == true)
        fake.requested = nil; fake.completion = nil
        input.cancel(); for char in "shi" { input.handle(key(String(char))) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertNil(fake.completion, "Reset client context must not be reused")
    }
    func testNavigatingCandidatesLocksOutPendingNeuralReorder() throws {
        let fake = ManualRanker(), requested = expectation(description: "model request")
        fake.requested = { requested.fulfill() }
        let input = try rankedInput(fake)
        for char in "shi" { input.handle(key(String(char))) }
        wait(for: [requested], timeout: 1)
        input.handle(key("", code: 124))
        let current = input.composition
        fake.completion?(Array(current.candidates.indices.reversed()))
        XCTAssertEqual(input.composition.candidates, current.candidates)
        XCTAssertEqual(input.composition.highlighted, 1)
    }

    func testPinyinSplitNavigationMatchesAppleSequence() throws {
        for expanded in [false, true] {
            let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false, expandedCandidates: expanded) })
            for char in "nihao" { _ = input.handle(key(String(char))) }
            XCTAssertEqual(input.composition.preedit, "ni hao")
            _ = input.handle(key("", code: 124)); XCTAssertEqual(input.composition.highlighted, 1)
            _ = input.handle(key("", code: 123)); XCTAssertEqual(input.composition.highlighted, 0)
            XCTAssertEqual(input.rime.caretPosition, 5)
            _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, 2)
            XCTAssertEqual(input.composition.candidates.first?.text, "你")
            _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, 0)
            XCTAssertEqual(input.composition.candidates.first?.text, "你好")
            _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, 0)
            for (offset, spelling) in ["n i hao", "ni hao", "ni h ao", "ni ha o", "ni hao"].enumerated() {
                _ = input.handle(key("", code: 124))
                XCTAssertEqual(input.rime.caretPosition, offset + 1)
                XCTAssertEqual(input.composition.preedit, spelling)
                XCTAssertEqual(input.composition.highlighted, 0)
                XCTAssertEqual(input.composition.rawInput, "nihao")
            }
            _ = input.handle(key("", code: 124)); XCTAssertEqual(input.composition.highlighted, 1)
            XCTAssertEqual(input.rime.caretPosition, 5)
        }
    }
    func testLeftMovesInsideSyllableThenJumpsAtBoundary() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
        for char in "nihao" { _ = input.handle(key(String(char))) }
        _ = input.handle(key("", code: 123)) // ni|hao
        _ = input.handle(key("", code: 124)); _ = input.handle(key("", code: 124)) // niha|o
        for expected in [3, 2, 0, 0] {
            _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, expected)
        }
        input.cancel()
        for char in "shu" { _ = input.handle(key(String(char))) }
        _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, 0)
        _ = input.handle(key("", code: 124)); XCTAssertEqual(input.composition.preedit, "s hu")
        _ = input.handle(key("", code: 124)); XCTAssertEqual(input.composition.preedit, "sh u")
        _ = input.handle(key("", code: 123)); XCTAssertEqual(input.composition.preedit, "s hu")
    }
    func testExplicitDelimiterAndTypingInsidePinyin() throws {
        let input = try InputSession(engine: XCTUnwrap(Self.engine), options: { InputOptions(learning: false) })
        for char in "ni'hao" { _ = input.handle(key(String(char))) }
        _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, 3)
        _ = input.handle(key("", code: 123)); XCTAssertEqual(input.rime.caretPosition, 0)
        input.cancel()
        for char in "nihao" { _ = input.handle(key(String(char))) }
        _ = input.handle(key("", code: 123)); _ = input.handle(key("m"))
        XCTAssertEqual(input.composition.rawInput, "nimhao")
        _ = input.handle(key("", code: 51)); XCTAssertEqual(input.composition.rawInput, "nihao")
        for _ in 0..<3 { _ = input.handle(key("", code: 124)) }
        XCTAssertEqual(input.rime.caretPosition, 5)
        XCTAssertEqual(input.composition.preedit, "ni hao")
    }

}

final class SymbolCatalogTests: XCTestCase {
    func testCLDRNamesPinyinKeywordsAndRanking() {
        XCTAssertGreaterThan(SymbolCatalog.entries.count, 1500)
        for (query, expected) in [("章鱼", "🐙"), ("zhangyu", "🐙"), ("octopus", "🐙"), ("狐狸", "🦊"), ("hu li", "🦊"), ("robot", "🤖"), ("机器人", "🤖")] {
            XCTAssertTrue(SymbolCatalog.search(query, kind: .emoji).prefix(8).contains { $0.text == expected }, query)
        }
        XCTAssertEqual(SymbolCatalog.search("微笑", kind: .emoji).first?.text, "😊")
        XCTAssertEqual(SymbolCatalog.search("🐙", kind: .emoji).first?.text, "🐙")
    }

    func testSearchSupportsChinesePinyinAndEnglish() {
        for query in ["蛇", "she", "SNAKE", "snake 动物"] {
            XCTAssertTrue(SymbolCatalog.search(query, kind: .emoji).contains { $0.text == "🐍" }, query)
        }
        XCTAssertTrue(SymbolCatalog.search("weixiao", kind: .kaomoji).allSatisfy { $0.kind == .kaomoji })
        XCTAssertTrue(SymbolCatalog.search("no such symbol 123").isEmpty)
    }
    func testRecentsDeduplicateAndNeverStoreClipboardText() {
        XCTAssertEqual(SymbolCatalog.recent(afterSelecting: "🐍", existing: ["😊", "🐍"]), ["🐍", "😊"])
        XCTAssertEqual(SymbolCatalog.recent(afterSelecting: "private clipboard text", existing: ["😊"]), ["😊"])
        let all = SymbolCatalog.entries.map(\.text)
        XCTAssertEqual(SymbolCatalog.recent(afterSelecting: "🐍", existing: all).count, 24)
    }
}

final class KeyboardAndPlacementTests: XCTestCase {
    func testShiftTapNeverConsumesModifiedTyping() {
        var shift = ShiftTapTracker()
        XCTAssertFalse(shift.flagsChanged(keyCode: 56, flags: .shift))
        XCTAssertTrue(shift.flagsChanged(keyCode: 56, flags: []))
        XCTAssertFalse(shift.flagsChanged(keyCode: 56, flags: .shift))
        shift.cancel() // Shift+A, or any non-modifier key
        XCTAssertFalse(shift.flagsChanged(keyCode: 56, flags: []))
        XCTAssertFalse(shift.flagsChanged(keyCode: 56, flags: [.shift, .command]))
        XCTAssertFalse(shift.flagsChanged(keyCode: 56, flags: .command))
    }

    func testKeysAndNonASCIIInput() {
        XCTAssertEqual(RimeKey.translate(keyCode: 123, characters: ""), RimeKey.left)
        XCTAssertEqual(RimeKey.translate(keyCode: 0, characters: "A"), 65)
        XCTAssertNil(RimeKey.translate(keyCode: 0, characters: "你"))
        XCTAssertNil(RimeKey.translate(keyCode: 0, characters: "ab"))
    }

    func testUTF8OffsetsBecomeUTF16WithoutSplittingScalars() {
        XCTAssertEqual(RimeSession.utf16Offset(in: "你😀hao", utf8Offset: 7), 3)
        XCTAssertEqual(RimeSession.utf16Offset(in: "lü", utf8Offset: 3), 2)
        XCTAssertEqual(RimeSession.utf16Offset(in: "你hao", utf8Offset: 2), 0)
        XCTAssertEqual(RimeSession.utf16Offset(in: "ni", utf8Offset: 999), 2)
    }

    func testPanelStaysOnScreenAndFlipsAboveBottomCaret() {
        let screen = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let size = NSSize(width: 450, height: 118)
        let right = PanelPlacement.frame(size: size, caret: NSRect(x: -5, y: 400, width: 1, height: 20), screen: screen)
        XCTAssertEqual(right.maxX, screen.maxX)
        let bottom = PanelPlacement.frame(size: size, caret: NSRect(x: -1800, y: 5, width: 1, height: 20), screen: screen)
        XCTAssertEqual(bottom.minY, 31)
        XCTAssertTrue(screen.contains(bottom))
        let snug = PanelPlacement.frame(size: size, caret: NSRect(x: -5, y: 400, width: 1, height: 20), screen: screen, gap: 1)
        XCTAssertEqual(snug.maxY, 399)
        let snugBottom = PanelPlacement.frame(size: size, caret: NSRect(x: -1800, y: 5, width: 1, height: 20), screen: screen, gap: 1)
        XCTAssertEqual(snugBottom.minY, 26)
        let oversized = PanelPlacement.frame(size: NSSize(width: 3000, height: 2000), caret: .zero, screen: screen)
        XCTAssertEqual(oversized, screen)
    }

}
