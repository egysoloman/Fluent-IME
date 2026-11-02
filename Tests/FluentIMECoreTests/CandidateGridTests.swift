import XCTest
import AppKit
@testable import FluentIMECore

/// Expanded rows hold as many candidates as fit, so navigation follows the view's rows.
final class CandidateGridTests: XCTestCase {
    func testNavigationFollowsVariableRows() throws {
        guard let precompiled = ProcessInfo.processInfo.environment["FLUENTIME_TEST_PRECOMPILED_DIR"] else { throw XCTSkip("Requires the packaged Rime data") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FluentGrid-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: precompiled), to: scratch.appendingPathComponent("shared"))
        let engine = try RimeEngine(sharedDirectory: scratch.appendingPathComponent("shared"), userDirectory: scratch.appendingPathComponent("user"))
        let options = InputOptions(learning: false, expandedCandidates: true)
        let input = try InputSession(engine: engine, options: { options })
        func key(_ characters: String, _ code: UInt16 = 0) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        for character in "bzdwsm" { XCTAssertTrue(input.handle(key(String(character)))) }
        XCTAssertTrue(input.composition.isContinuous && input.composition.candidates.count > 12)
        // Rows of 2, 3 and 6 candidates, as long candidates would be laid out.
        input.setCandidateRows([0, 2, 5, 11], covering: 12)
        XCTAssertTrue(input.handle(key("", 125))); XCTAssertEqual(input.composition.highlighted, 2, "↓ keeps the column")
        XCTAssertTrue(input.handle(key("", 124))); XCTAssertTrue(input.handle(key("", 124)))
        XCTAssertEqual(input.composition.highlighted, 4)
        XCTAssertTrue(input.handle(key("", 125))); XCTAssertEqual(input.composition.highlighted, 7, "Column 2 of the six-wide row")
        XCTAssertTrue(input.handle(key("", 124))); XCTAssertTrue(input.handle(key("", 124))); XCTAssertTrue(input.handle(key("", 124)))
        XCTAssertEqual(input.composition.highlighted, 10)
        XCTAssertTrue(input.handle(key("", 126))); XCTAssertEqual(input.composition.highlighted, 4, "↑ clamps to the shorter row")
        XCTAssertTrue(input.handle(key("", 126))); XCTAssertEqual(input.composition.highlighted, 1)
        // Number keys choose within the row the view numbers.
        let expected = input.composition.candidates[3].text
        input.setCandidateViewport(start: 2, columns: 3)
        var committed = ""; input.onCommit = { committed += $0 }
        XCTAssertTrue(input.handle(key("2")))
        XCTAssertTrue(committed.hasPrefix(expected) || input.composition.preedit.hasPrefix(expected), "2 chooses the row's second candidate")
    }
}
