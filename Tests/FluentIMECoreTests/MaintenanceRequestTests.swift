import XCTest
import CryptoKit
@testable import FluentIMECore

final class MaintenanceRequestTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("FluentMaintenanceTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    func testUninstallChoiceIsPreservedAndRequestCanOnlyRunOnce() throws {
        let store = MaintenanceRequestStore(support: home)
        for keep in [true, false] {
            let request = MaintenanceRequest.uninstall(keepData: keep)
            let file = try store.create(request)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try store.consume(file), request)
            XCTAssertThrowsError(try store.consume(file))
        }
    }
    func testStaleOrFutureRequestsDoNotRun() throws {
        let store = MaintenanceRequestStore(support: home), now = Date()
        for difference: TimeInterval in [-121, 10] {
            let file = try store.create(.uninstall(keepData: false), now: now.addingTimeInterval(difference))
            XCTAssertThrowsError(try store.consume(file, now: now))
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }
    func testOutsideFilesAndSymlinksAreNeverConsumed() throws {
        let store = MaintenanceRequestStore(support: home), file = try store.create(.show)
        let outside = home.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: file, to: outside)
        XCTAssertThrowsError(try store.consume(outside))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        let link = store.directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try store.consume(link))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
    func testWritableByOtherAccountsOrMalformedRequestsAreRejected() throws {
        let store = MaintenanceRequestStore(support: home)
        let file = try store.create(.show)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.consume(file))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try Data("not a request".utf8).write(to: file)
        XCTAssertThrowsError(try store.consume(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    private func update() throws -> (URL, URL) {
        let updates = home.appendingPathComponent("Updates")
        let folder = updates.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Fluent-IME-99.1.0-Full-Setup.dmg")
        let data = Data("verified download fixture".utf8)
        try data.write(to: file)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try VerifiedUpdateReceipt(version: "99.1.0", edition: .full, size: Int64(data.count), sha256: sha).save(beside: file)
        return (file, updates)
    }
    func testMaintenanceRechecksBytesVersionAndDownloadLocation() throws {
        let (file, updates) = try update()
        XCTAssertEqual(try VerifiedUpdateReceipt.validate(file: file, version: "99.1.0", updates: updates).edition, .full)
        XCTAssertThrowsError(try VerifiedUpdateReceipt.validate(file: file, version: "99.1.1", updates: updates))
        XCTAssertThrowsError(try VerifiedUpdateReceipt.validate(file: file, version: "99.1.0", updates: home))
        try Data("changed after download".utf8).write(to: file)
        XCTAssertThrowsError(try VerifiedUpdateReceipt.validate(file: file, version: "99.1.0", updates: updates))
    }
    func testMaintenanceRejectsSymlinkedDownloadsAndMissingReceipt() throws {
        let (file, updates) = try update()
        let moved = home.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        XCTAssertThrowsError(try VerifiedUpdateReceipt.validate(file: file, version: "99.1.0", updates: updates))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: moved, to: file)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent(VerifiedUpdateReceipt.filename))
        XCTAssertThrowsError(try VerifiedUpdateReceipt.validate(file: file, version: "99.1.0", updates: updates))
    }
}
