import XCTest
import AppKit
@testable import FluentIMECore
final class CaretAnchorTests: XCTestCase {
    private let screens = [NSRect(x: -1920, y: 0, width: 1920, height: 1080), NSRect(x: 0, y: 0, width: 1920, height: 1080)]
    func testDocumentRangeIsUsedWhenInlineGeometryIsUnavailable() {
        let expected = NSRect(x: 27, y: 300, width: 1, height: 20)
        let anchor = CaretAnchor.resolve(marked: NSRange(location: 500, length: 5), selected: NSRange(location: 505, length: 0), screens: screens, documentRect: { range in
            XCTAssertEqual(range, NSRange(location: 500, length: 0)); return expected
        }, inlineRect: { .zero })
        XCTAssertEqual(anchor, expected)
    }
    func testIMKLineRectangleWinsOverUnreliableDocumentBridge() {
        let line = NSRect(x: 535, y: 320, width: 1, height: 16)
        let anchor = CaretAnchor.resolve(marked: NSRange(location: 0, length: 4), selected: NSRange(location: 4, length: 0), screens: screens, documentRect: { _ in
            XCTFail("Do not query the unreliable document bridge when IMK supplies a line rectangle")
            return NSRect(x: 0, y: 0, width: 1, height: 1.6080749353408704e-314)
        }, inlineRect: { line })
        XCTAssertEqual(anchor, line)
        let panel = PanelPlacement.frame(size: NSSize(width: 578, height: 36), caret: try! XCTUnwrap(anchor), screen: screens[1], gap: 4)
        XCTAssertEqual(panel.maxY, line.minY - 4)
    }
    func testRejectsSubnormalHeightObservedInHostTrace() {
        for height in [CGFloat(1.6080749353408704e-314), 0.1, 0, .nan, .infinity] {
            XCTAssertNil(CaretAnchor.resolve(marked: NSRange(location: 0, length: 1), selected: NSRange(location: 1, length: 0), screens: screens, documentRect: { _ in NSRect(x: 0, y: 0, width: 1, height: height) }, inlineRect: { .zero }))
        }
    }
    func testBeforeFirstMarkUsesCurrentSelectionAndSupportsOtherScreen() {
        let expected = NSRect(x: -1300, y: 300, width: 1, height: 20)
        XCTAssertEqual(CaretAnchor.resolve(marked: NSRange(location: NSNotFound, length: 0), selected: NSRange(location: 30, length: 0), screens: screens, documentRect: { range in
            XCTAssertEqual(range.location, 30); return expected
        }, inlineRect: { .zero }), expected)
    }
    func testMissingGeometryDoesNotInventAMouseAnchor() {
        XCTAssertNil(CaretAnchor.resolve(marked: NSRange(location: NSNotFound, length: 0), selected: NSRange(location: NSNotFound, length: 0), screens: screens, documentRect: { _ in XCTFail(); return .zero }, inlineRect: { .zero }))
        XCTAssertNil(CaretAnchor.resolve(marked: NSRange(location: 0, length: 0), selected: NSRange(location: 0, length: 0), screens: screens, documentRect: { _ in NSRect(x: 1e9, y: 10, width: 1, height: 20) }, inlineRect: { NSRect(x: CGFloat.nan, y: 0, width: 1, height: 20) }))
    }
}
