import XCTest
@testable import FluentIMECore

final class ModeIndicatorTests: XCTestCase {
    func testFocusAndRepeatedUpdatesDoNotShowHint() {
        var state = ModeIndicatorRequest()
        for mode in InputMode.allCases {
            state.activate(mode: mode)
            XCTAssertNil(state.changed(to: mode))
            state.deactivate()
            XCTAssertNil(state.changed(to: .english))
        }
    }
    func testTypingBlurAndNewFocusCancelQueuedHint() throws {
        var state = ModeIndicatorRequest()
        state.activate(mode: .simplifiedChinese)
        let first = try XCTUnwrap(state.changed(to: .english))
        XCTAssertTrue(state.accepts(first))
        XCTAssertNil(state.changed(to: .english))
        state.cancel()
        XCTAssertFalse(state.accepts(first))
        let second = try XCTUnwrap(state.changed(to: .traditionalChinese))
        state.deactivate()
        XCTAssertFalse(state.accepts(second))
        state.activate(mode: .traditionalChinese)
        XCTAssertFalse(state.accepts(second))
        XCTAssertNil(state.changed(to: .traditionalChinese))
        let third = try XCTUnwrap(state.changed(to: .english))
        let fourth = try XCTUnwrap(state.changed(to: .simplifiedChinese))
        XCTAssertFalse(state.accepts(third))
        XCTAssertTrue(state.accepts(fourth))
    }
}
