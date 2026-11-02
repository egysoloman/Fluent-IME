import XCTest
import AppKit
import CryptoKit
@testable import FluentIMECore

final class ClipboardVaultTests: XCTestCase {
    private final class SlowStorage: ClipboardStoring {
        let gate = DispatchSemaphore(value: 0)
        var authorized: (() -> Void)?
        var pins: [ClipboardEntry] = []
        var fails = false
        func authorize() throws {
            XCTAssertFalse(Thread.isMainThread)
            authorized?()
            guard gate.wait(timeout: .now() + 3) == .success, !fails else { throw ClipboardError.storage }
        }
        func load() throws -> [ClipboardEntry] { pins }
        func save(_ entries: [ClipboardEntry]) throws { XCTAssertFalse(Thread.isMainThread); pins = entries }
        func erase() throws { XCTAssertFalse(Thread.isMainThread); pins = [] }
    }
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
    func testPinAuthorizationDoesNotBlockTypingOrLoseNewCopies() throws {
        let storage = SlowStorage()
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: storage)
        history.setRecording(true); text("pin this"); history.poll()
        let id = history.entries[0].id
        let authorization = expectation(description: "background authorization")
        let saved = expectation(description: "saved")
        storage.authorized = { authorization.fulfill() }
        history.setPinned(id, true) { result in
            XCTAssertTrue(Thread.isMainThread); if case .failure(let error) = result { XCTFail(error.localizedDescription) }; saved.fulfill()
        }
        XCTAssertTrue(history.isStorageBusy)
        wait(for: [authorization], timeout: 2)
        // The main run loop and pasteboard polling keep working during the prompt.
        text("copied while authorizing"); history.poll()
        history.clear { result in
            guard case .failure(ClipboardError.busy) = result else { return XCTFail("clear must not race a pending save") }
        }
        history.setPinned(id, true) { result in
            guard case .failure(ClipboardError.busy) = result else { return XCTFail("duplicate pin must not race") }
        }
        storage.gate.signal(); wait(for: [saved], timeout: 2)
        XCTAssertFalse(history.isStorageBusy)
        XCTAssertEqual(history.entries.map(\.text), ["pin this", "copied while authorizing"])
        XCTAssertTrue(history.entries[0].isPinned)
        let cleared = expectation(description: "clear after save")
        history.clear { result in if case .failure(let error) = result { XCTFail(error.localizedDescription) }; cleared.fulfill() }
        wait(for: [cleared], timeout: 2)
        XCTAssertTrue(history.entries.isEmpty); XCTAssertTrue(storage.pins.isEmpty)
    }
    func testRejectedAsyncPinKeepsHistoryAndExistingPins() {
        let storage = SlowStorage(); storage.fails = true
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: storage)
        history.setRecording(true); text("keep this"); history.poll()
        let original = history.entries, done = expectation(description: "rejected")
        history.setPinned(original[0].id, true) { result in
            if case .success = result { XCTFail("Expected authorization failure") }; done.fulfill()
        }
        storage.gate.signal(); wait(for: [done], timeout: 2)
        XCTAssertEqual(history.entries, original); XCTAssertFalse(history.isStorageBusy)
        XCTAssertNotNil(history.storageError); XCTAssertTrue(storage.pins.isEmpty)
    }
    func testOptionalEncryptionMigratesAtomicallyAndPlainModeNeverReadsKey() throws {
        var keyReads = 0
        let storage = ClipboardVault(directory: directory, encrypted: false, key: { [key] _ in keyReads += 1; return key })
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: storage)
        history.setRecording(true); text("optional encryption fixture"); history.poll()
        try history.setPinned(history.entries[0].id, true)
        let file = directory.appendingPathComponent("pinned.aesgcm")
        let plain = try Data(contentsOf: file)
        XCTAssertNotNil(plain.range(of: Data(Data("optional encryption fixture".utf8).base64EncodedString().utf8)))
        XCTAssertEqual(keyReads, 0)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try storage.setEncryption(true)
        XCTAssertNil(try Data(contentsOf: file).range(of: Data("optional encryption fixture".utf8)))
        XCTAssertEqual(try storage.load(), history.entries)
        try storage.save(history.entries); _ = try storage.load()
        XCTAssertEqual(keyReads, 1, "Reuse the key after successful authorization")
        try storage.setEncryption(false)
        XCTAssertTrue(try Data(contentsOf: file).starts(with: Data("FluentIME.Clipboard.plain.v1\n".utf8)))
        XCTAssertEqual(try storage.load(), history.entries)
        // File format wins over a stale preference after an interrupted preference update.
        let reopened = ClipboardVault(directory: directory, encrypted: true, key: { _ in XCTFail("Plain file must not access Keychain"); throw ClipboardError.storage })
        try reopened.authorize()
        XCTAssertEqual(try reopened.load(), history.entries); XCTAssertFalse(reopened.isEncrypted)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["pinned.aesgcm"])
    }
    func testFailedEncryptionMigrationLeavesOriginalFileAndMode() throws {
        let storage = ClipboardVault(directory: directory, encrypted: false, key: { _ in throw ClipboardError.storage })
        let history = ClipboardHistory(pasteboard: board, automaticPolling: false, sensitiveInput: { false }, storage: storage)
        history.setRecording(true); text("preserve on failure"); history.poll()
        try history.setPinned(history.entries[0].id, true)
        let file = directory.appendingPathComponent("pinned.aesgcm"), original = try Data(contentsOf: file)
        XCTAssertThrowsError(try storage.setEncryption(true))
        XCTAssertFalse(storage.isEncrypted); XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try storage.load(), history.entries)
        let encrypted = vault(); try encrypted.save(history.entries)
        let ciphertext = try Data(contentsOf: file)
        let locked = ClipboardVault(directory: directory, key: { _ in throw ClipboardError.storage })
        XCTAssertThrowsError(try locked.setEncryption(false))
        XCTAssertTrue(locked.isEncrypted); XCTAssertEqual(try Data(contentsOf: file), ciphertext)
    }
}
