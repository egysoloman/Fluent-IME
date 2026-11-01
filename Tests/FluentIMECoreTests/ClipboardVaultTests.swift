import XCTest
import AppKit
import CryptoKit
@testable import FluentIMECore

final class ClipboardVaultTests: XCTestCase {
    private var board: NSPasteboard!
    private var directory: URL!
    private let key = SymmetricKey(size: .bits256)
    override func setUpWithError() throws {
        board = NSPasteboard(name: .init("FluentIME-VaultTest-" + UUID().uuidString))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-VaultTest-" + UUID().uuidString)
    }
    override func tearDownWithError() throws {
        board.releaseGlobally()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func copy(_ values: [[NSPasteboard.PasteboardType: Data]]) {
        board.clearContents()
        board.writeObjects(values.map { values in
            let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
        })
    }
    private func text(_ value: String) { copy([[.string: Data(value.utf8)]]) }
    private func vault() -> ClipboardVault { ClipboardVault(directory: directory, key: { [key] _ in key }) }
    func testOnlyPinnedPayloadsPersistEncryptedAndClearRemovesThem() throws {
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: vault())
        history.setRecording(true)
        text("private sample 123"); history.poll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let id = try XCTUnwrap(history.entries.first?.id)
        try history.setPinned(id, true)
        let file = directory.appendingPathComponent("pinned.aesgcm")
        let encrypted = try Data(contentsOf: file)
        XCTAssertNil(encrypted.range(of: Data("private sample 123".utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        text("temporary only"); history.poll()
        let restored = ClipboardHistory(pasteboard: board, automaticPolling: false, storage: vault())
        XCTAssertEqual(restored.entries.map(\.text), ["private sample 123"])
        XCTAssertFalse(restored.isRecording)
        try restored.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(ClipboardHistory(pasteboard: board, automaticPolling: false, storage: vault()).entries.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "temporary only")
    }
    func testExpiryExemptsPinsAndUnpinUsesOriginalTimestamp() throws {
        var time = Date()
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, now: { time }, sensitiveInput: { false }, storage: vault())
        history.setRecording(true); text("pin"); history.poll()
        let id = history.entries[0].id; try history.setPinned(id, true)
        text("temporary"); history.poll(); history.setRecording(false)
        time += 1000; history.setRetention(900)
        XCTAssertEqual(history.entries.map(\.text), ["pin"])
        try history.setPinned(id, false)
        XCTAssertTrue(history.entries.isEmpty); XCTAssertTrue(try vault().load().isEmpty)
        history.setRetention(0); history.setRecording(true); text("session"); history.poll()
        time += 1_000_000; history.poll(); XCTAssertEqual(history.entries.count, 1)
    }
    func testMultiItemFilesAndRichTextRoundTripWithoutOpeningFiles() throws {
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: vault())
        history.setRecording(true)
        let files: [[NSPasteboard.PasteboardType: Data]] = [[.fileURL: Data("file:///tmp/not-created-a.txt".utf8)], [.fileURL: Data("file:///tmp/not-created-b.txt".utf8)]]
        copy(files); history.poll()
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.kind, .files); XCTAssertEqual(entry.items.count, 2)
        try history.setPinned(entry.id, true)
        XCTAssertEqual(try vault().load().first?.items, entry.items)
        XCTAssertTrue(history.copy(entry, to: board)); history.poll(); XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(board.pasteboardItems?.map { $0.string(forType: .fileURL)! }, ["file:///tmp/not-created-a.txt", "file:///tmp/not-created-b.txt"])
        let html = Data("<b>example</b><img src='https://example.invalid/never-fetch'>".utf8)
        copy([[.html: html, .string: Data("example".utf8)]]); history.poll()
        let rich = history.entries[0]; XCTAssertEqual(rich.kind, .richText)
        XCTAssertTrue(history.copy(rich, to: board)); XCTAssertEqual(board.data(forType: .html), html)
        XCTAssertEqual(board.string(forType: .string), "example")
    }
    func testImagesHaveThumbnailAndRestoreOriginalRepresentation() throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 96, bitsPerPixel: 32)!
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: vault())
        history.setRecording(true); copy([[.png: png]]); history.poll()
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertEqual(entry.kind, .image); XCTAssertNotNil(entry.thumbnail())
        try history.setPinned(entry.id, true)
        XCTAssertTrue(history.copy(try XCTUnwrap(vault().load().first), to: board))
        XCTAssertEqual(board.data(forType: .png), png)
    }
    func testPrivacyMarkerOnAnyItemRejectsWholeCopy() {
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false })
        history.setRecording(true)
        copy([[.string: Data("ordinary".utf8)], [.string: Data("private".utf8), .init("org.nspasteboard.ConcealedType"): Data()]])
        history.poll(); XCTAssertTrue(history.entries.isEmpty)
    }
    func testMissingKeyAndTamperingNeverOverwriteExistingVault() throws {
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: vault())
        history.setRecording(true); text("existing"); history.poll(); try history.setPinned(history.entries[0].id, true)
        let file = directory.appendingPathComponent("pinned.aesgcm"), original = try Data(contentsOf: file)
        let locked = ClipboardVault(directory: directory, key: { _ in throw ClipboardError.storage })
        let second = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: locked)
        XCTAssertNotNil(second.storageError)
        second.setRecording(true); text("new"); second.poll()
        XCTAssertThrowsError(try second.setPinned(second.entries[0].id, true))
        XCTAssertEqual(try Data(contentsOf: file), original)
        var tampered = original; tampered[tampered.count - 1] ^= 1; try tampered.write(to: file)
        XCTAssertThrowsError(try vault().load())
        let third = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: vault())
        XCTAssertNotNil(third.storageError); XCTAssertEqual(try Data(contentsOf: file), tampered)
        try third.clear(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
