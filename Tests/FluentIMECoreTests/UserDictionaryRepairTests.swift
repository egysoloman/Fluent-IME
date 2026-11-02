import XCTest
import AppKit
@testable import FluentIMECore

/// LevelDB rejects writes after it meets a corrupted block; learning must not stop for good.
final class UserDictionaryRepairTests: XCTestCase {
    private func event(_ characters: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    private func choose(_ word: String, typing code: String, in input: InputSession) -> [String] {
        for character in code { _ = input.handle(event(String(character))) }
        let page = input.composition.candidates.map(\.text)
        if let index = page.firstIndex(of: word), index < 7 { _ = input.handle(event(String(index + 1))) } else { input.cancel() }
        return page
    }

    func testDamagedDictionaryIsRebuiltWithItsLearning() throws {
        guard let precompiled = ProcessInfo.processInfo.environment["FLUENTIME_TEST_PRECOMPILED_DIR"] else { throw XCTSkip("Requires the packaged Rime data") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FluentRepair-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let shared = scratch.appendingPathComponent("support/shared"), user = scratch.appendingPathComponent("support/Rime")
        try FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: precompiled), to: shared)
        let options = InputOptions(learning: true)
        do {
            let engine = try RimeEngine(sharedDirectory: shared, userDirectory: user)
            let input = try InputSession(engine: engine, options: { options })
            XCTAssertEqual(choose("中国", typing: "zg", in: input).first, "这个")
            XCTAssertEqual(choose("中国", typing: "zg", in: input).first, "中国", "One choice is learned")
        }
        let database = user.appendingPathComponent("pinyin_simp.userdb")
        let log = database.appendingPathComponent("LOG")
        try (String(contentsOf: log, encoding: .utf8) + "Compaction error: Corruption: corrupted compressed block contents\n").write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: user.appendingPathComponent("build-0.6.4"), withIntermediateDirectories: true)

        let engine = try RimeEngine(sharedDirectory: shared, userDirectory: user)
        let backups = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("support/DictionaryBackups").path)
        XCTAssertEqual(backups.count, 1)
        let backup = scratch.appendingPathComponent("support/DictionaryBackups").appendingPathComponent(backups[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("pinyin_simp.userdb").path), "The damaged database is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("pinyin_simp.userdb.txt").path), "So is the export")
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("Corruption:"), "The rebuilt database is clean")
        XCTAssertFalse(FileManager.default.fileExists(atPath: user.appendingPathComponent("build-0.6.4").path), "Earlier releases' caches are removed")
        let input = try InputSession(engine: engine, options: { options })
        XCTAssertEqual(choose("中国", typing: "zg", in: input).first, "中国", "Learning survived the rebuild")
        XCTAssertEqual(choose("那个", typing: "ng", in: input).first, "能够")
        XCTAssertEqual(choose("那个", typing: "ng", in: input).first, "那个", "New choices are learned again")
    }
}
