import XCTest
import AppKit
@testable import FluentIMECore

final class KeyShortcutTests: XCTestCase {
    private func event(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testRecordingMatchingAndDisplay() throws {
        let recorded = try XCTUnwrap(KeyShortcut(event: event("e", code: 14, flags: [.control, .option])))
        XCTAssertEqual(recorded, .emojiDefault)
        XCTAssertEqual(recorded.display, "⌃⌥E")
        XCTAssertEqual(KeyShortcut(keyCode: 9, flags: [.command, .shift, .control], key: "v").display, "⌃⇧⌘V", "macOS order ⌃⌥⇧⌘")
        // Physical key and exact modifiers; Caps Lock and the function key do not matter.
        XCTAssertTrue(recorded.matches(event("é", code: 14, flags: [.control, .option, .capsLock, .function])))
        XCTAssertFalse(recorded.matches(event("e", code: 14, flags: [.control, .option, .shift])))
        XCTAssertFalse(recorded.matches(event("r", code: 15, flags: [.control, .option])))
        XCTAssertEqual(try JSONDecoder().decode(KeyShortcut.self, from: JSONEncoder().encode(recorded)), recorded)
    }

    func testConflictDetection() {
        func shortcut(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> KeyShortcut { KeyShortcut(keyCode: code, flags: flags, key: "X") }
        XCTAssertNil(ShortcutValidator.conflict(for: .emojiDefault, other: .clipboardDefault, system: []))
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(14, []), other: nil, system: []), .needsModifier)
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(14, .shift), other: nil, system: []), .needsModifier)
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(14, [.option, .shift]), other: nil, system: []), .typesCharacters)
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(9, .command), other: nil, system: []), .common, "⌘V pastes")
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(6, [.shift, .command]), other: nil, system: []), .common, "⇧⌘Z redoes")
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(49, [.control, .command]), other: nil, system: []), .common, "⌃⌘Space is the emoji viewer")
        XCTAssertEqual(ShortcutValidator.conflict(for: shortcut(14, [.control, .option]), other: nil, system: [shortcut(14, [.control, .option])]), .system)
        XCTAssertEqual(ShortcutValidator.conflict(for: .clipboardDefault, other: .clipboardDefault, system: []), .duplicate)
        XCTAssertNil(ShortcutValidator.conflict(for: shortcut(9, [.control, .shift]), other: .emojiDefault, system: []))
    }

    func testSystemShortcutsUseTheSymbolicHotKeyFormat() {
        // parameters are [character, key code, modifier mask]; the mask matches NSEvent's flags.
        for item in ShortcutValidator.systemShortcuts() {
            XCTAssertFalse(item.flags.isEmpty && item.keyCode > 127, "Malformed system shortcut \(item)")
        }
    }

    func testIndicatorIsCenteredOnTheCaret() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let centered = PanelPlacement.frame(size: NSSize(width: 28, height: 20), caret: NSRect(x: 500, y: 400, width: 2, height: 18), screen: screen, gap: 5, centered: true)
        XCTAssertEqual(centered.midX, 501, accuracy: 0.001)
        XCTAssertEqual(centered.maxY, 395, accuracy: 0.001)
        let edge = PanelPlacement.frame(size: NSSize(width: 38, height: 28), caret: NSRect(x: 2, y: 400, width: 2, height: 18), screen: screen, centered: true)
        XCTAssertEqual(edge.minX, 0, "Kept on screen at the left edge")
        let candidates = PanelPlacement.frame(size: NSSize(width: 300, height: 40), caret: NSRect(x: 500, y: 400, width: 2, height: 18), screen: screen)
        XCTAssertEqual(candidates.minX, 500, "The candidate window stays left-aligned")
    }
}
