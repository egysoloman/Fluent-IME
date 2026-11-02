import XCTest
import AppKit
@testable import FluentIMECore

/// Real Zhuyin sessions: packaged Rime data → C bridge → InputSession, driven by key events.
final class ZhuyinSessionTests: XCTestCase {
    private static var engine: RimeEngine!
    private static var scratch: URL!

    override class func setUp() {
        super.setUp()
        guard let precompiled = ProcessInfo.processInfo.environment["FLUENTIME_TEST_PRECOMPILED_DIR"] else { return }
        do {
            scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FluentZhuyinTests-" + UUID().uuidString)
            let shared = scratch.appendingPathComponent("shared")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: precompiled), to: shared)
            engine = try RimeEngine(sharedDirectory: shared, userDirectory: scratch.appendingPathComponent("user"))
        } catch { XCTFail("Cannot prepare engine: \(error)") }
    }
    override class func tearDown() {
        engine = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }
    override func setUpWithError() throws {
        guard Self.engine != nil else { throw XCTSkip("Requires FLUENTIME_TEST_PRECOMPILED_DIR with the packaged Zhuyin data") }
    }

    private func session(mode: InputMode = .traditionalChinese, keyboard: InputKeyboard = .zhuyin, learning: Bool = false) throws -> (InputSession, () -> String) {
        let options = InputOptions(learning: learning, defaultMode: mode)
        let input = try InputSession(engine: XCTUnwrap(Self.engine), keyboard: keyboard, options: { options })
        var committed = ""
        input.onCommit = { committed += $0 }
        return (input, { committed })
    }
    private func event(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    /// Types Zhuyin on 大千; "ˉ" is the first tone (Space).
    private func type(_ zhuyin: String, into input: InputSession) {
        let keys = Dictionary(uniqueKeysWithValues: zip("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˊˇˋ˙", "1qaz2wsxedcrfv5tgbyhnujm8ik,9ol.0p;/-6347"))
        for symbol in zhuyin {
            if symbol == "ˉ" { XCTAssertTrue(input.handle(event(" ", code: 49)), "Space after a syllable is its first tone") }
            else { XCTAssertTrue(input.handle(event(String(keys[symbol]!))), "Key for \(symbol)") }
        }
    }
    private func openList(_ input: InputSession) { XCTAssertTrue(input.handle(event("", code: 125))) }
    private func enter(_ input: InputSession) { XCTAssertTrue(input.handle(event("\r", code: 36))) }
    private func texts(_ input: InputSession) -> [String] { input.composition.candidates.map(\.text) }

    func testToneNarrowsCandidates() throws {
        // Each tone offers its reading and drops the others (麼 also reads ma2).
        let expected: [(String, String, String)] = [("ㄇㄚˉ", "媽", "罵"), ("ㄇㄚˊ", "麻", "媽"), ("ㄇㄚˇ", "馬", "罵"), ("ㄇㄚˋ", "罵", "馬")]
        for (spelling, wanted, absent) in expected {
            let (input, _) = try session()
            type(spelling, into: input); openList(input)
            let page = texts(input)
            XCTAssertTrue(page.prefix(3).contains(wanted), "\(spelling): \(page)")
            XCTAssertFalse(page.contains(absent), "\(spelling) must not offer \(absent) from another tone: \(page)")
        }
        // Without a tone every reading stays available.
        let (toneless, _) = try session()
        type("ㄇㄚ", into: toneless); openList(toneless)
        XCTAssertTrue(Set(texts(toneless)).isSuperset(of: ["媽", "麻", "馬", "罵"]), "\(texts(toneless))")
    }

    func testNeutralToneAndHomophones() throws {
        let (particle, _) = try session()
        type("ㄇㄚ˙", into: particle); openList(particle)
        XCTAssertEqual(texts(particle).first, "嗎", "\(texts(particle))")
        let (thing, committed) = try session()
        type("ㄉㄨㄥˉㄒㄧ˙", into: thing)
        XCTAssertEqual(thing.composition.preedit, "東西")
        enter(thing); XCTAssertEqual(committed(), "東西")
        let (homophones, _) = try session()
        type("ㄕˋ", into: homophones); openList(homophones)
        XCTAssertTrue(Set(texts(homophones)).isSuperset(of: ["是", "事", "市"]), "\(texts(homophones))")
    }

    func testInlinePhraseAndSentenceCommit() throws {
        let (phrase, committed) = try session()
        type("ㄋㄧˇㄏㄠˇ", into: phrase)
        XCTAssertTrue(phrase.composition.candidates.isEmpty, "The list stays hidden while typing")
        XCTAssertEqual(phrase.composition.preedit, "你好")
        enter(phrase); XCTAssertEqual(committed(), "你好"); XCTAssertFalse(phrase.composition.isComposing)
        let (sentence, said) = try session()
        type("ㄨㄛˇㄇㄣ˙ㄕˋㄒㄩㄝˊㄕㄥˉ", into: sentence)
        XCTAssertEqual(sentence.composition.preedit, "我們是學生")
        enter(sentence); XCTAssertEqual(said(), "我們是學生")
    }

    func testPendingSymbolsShowAsZhuyin() throws {
        let (input, _) = try session()
        type("ㄋㄧˇㄏ", into: input)
        let preedit = input.composition.preedit
        XCTAssertFalse(preedit.contains { $0.isASCII && $0.isLetter }, "Keys must never show as Latin letters: \(preedit)")
        XCTAssertTrue(preedit.hasPrefix("你") || preedit.hasPrefix("ㄋ"), preedit)
    }

    func testCandidateSelectionByDigitsAndShiftDigits() throws {
        let (digits, committed) = try session()
        type("ㄕˋ", into: digits)
        XCTAssertTrue(digits.handle(event(" ", code: 49)), "Space on a finished syllable opens the list")
        let page = texts(digits); XCTAssertGreaterThan(page.count, 2)
        XCTAssertTrue(digits.handle(event("2")))
        XCTAssertTrue(digits.composition.candidates.isEmpty, "Choosing closes the list")
        XCTAssertEqual(digits.composition.preedit, page[1], "Choosing replaces the text and keeps composing, as in 新注音")
        enter(digits); XCTAssertEqual(committed(), page[1])
        let (shifted, shiftCommitted) = try session()
        type("ㄕˋ", into: shifted); openList(shifted)
        let shiftedPage = texts(shifted)
        XCTAssertTrue(shifted.handle(event("#", flags: .shift)))
        enter(shifted); XCTAssertEqual(shiftCommitted(), shiftedPage[2])
        // With the list closed a digit is a Zhuyin key, not a selection.
        let (typing, typed) = try session()
        type("ㄕˋ", into: typing)
        XCTAssertTrue(typing.handle(event("1")))
        XCTAssertEqual(typed(), "")
        XCTAssertTrue(typing.composition.rawInput.hasSuffix("1"))
    }

    func testListNavigationAndEscape() throws {
        let (input, committed) = try session()
        type("ㄕˋ", into: input); openList(input)
        let page = texts(input)
        XCTAssertTrue(input.handle(event("", code: 124)))
        XCTAssertEqual(input.composition.highlighted, 1)
        XCTAssertTrue(input.handle(event("\u{1b}", code: 53)))
        XCTAssertTrue(input.composition.candidates.isEmpty && input.composition.isComposing, "Esc closes the list only")
        openList(input); XCTAssertTrue(input.handle(event("", code: 124)))
        enter(input); XCTAssertEqual(input.composition.preedit, page[1])
        enter(input); XCTAssertEqual(committed(), page[1])
    }

    func testCaretEditsEarlierText() throws {
        let (input, committed) = try session()
        type("ㄋㄧˇㄏㄠˇㄇㄚ˙", into: input)
        XCTAssertEqual(input.composition.preedit, "你好嗎")
        XCTAssertTrue(input.handle(event("", code: 123)))
        XCTAssertLessThan(input.composition.cursorUTF16, input.composition.preedit.utf16.count, "← moves into the text")
        openList(input)
        let before = texts(input)
        XCTAssertTrue(before.contains("你好"), "The list offers the text before the caret: \(before)")
        XCTAssertTrue(input.handle(event(String(before.firstIndex(of: "你好")! + 1))))
        XCTAssertTrue(input.composition.isComposing, "The rest stays in the composition")
        enter(input); XCTAssertEqual(committed(), "你好嗎")
    }

    func testSimplifiedAndTraditionalOutput() throws {
        let (traditional, tCommitted) = try session(mode: .traditionalChinese)
        type("ㄋㄧˇㄇㄣ˙", into: traditional); enter(traditional)
        XCTAssertEqual(tCommitted(), "你們")
        let (simplified, sCommitted) = try session(mode: .simplifiedChinese)
        type("ㄋㄧˇㄇㄣ˙", into: simplified); enter(simplified)
        XCTAssertEqual(sCommitted(), "你们")
    }

    func testShiftedPunctuationWithListClosed() throws {
        let (input, committed) = try session()
        type("ㄏㄠˇ", into: input)
        // Rime commits the converted text together with the punctuation.
        XCTAssertTrue(input.handle(event("<", code: 43, flags: .shift)))
        XCTAssertEqual(committed(), "好，")
        XCTAssertFalse(input.composition.isComposing)
    }

    func testSwitchingKeyboardsKeepsPinyinIntact() throws {
        let (input, committed) = try session(mode: .traditionalChinese, keyboard: .pinyin)
        for character in "nihao" { XCTAssertTrue(input.handle(event(String(character)))) }
        XCTAssertTrue(input.handle(event(" ", code: 49)))
        XCTAssertEqual(committed(), "你好")
        input.setKeyboard(.zhuyin)
        XCTAssertEqual(input.keyboard, .zhuyin)
        type("ㄋㄧˇㄏㄠˇ", into: input); enter(input)
        XCTAssertEqual(committed(), "你好你好")
        input.setKeyboard(.pinyin)
        for character in "nihao" { XCTAssertTrue(input.handle(event(String(character)))) }
        XCTAssertFalse(input.composition.candidates.isEmpty, "Pinyin shows its candidates while typing")
        XCTAssertEqual(input.composition.candidates.first?.text, "你好")
        XCTAssertEqual(InputKeyboard(sourceID: "org.fluentime.inputmethod.FluentIME.Bopomofo"), .zhuyin)
        XCTAssertEqual(InputKeyboard(sourceID: "org.fluentime.inputmethod.FluentIME.Hans"), .pinyin)
    }
}
