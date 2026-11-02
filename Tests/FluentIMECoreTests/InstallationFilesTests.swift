import XCTest
@testable import FluentIMECore

final class InstallationFilesTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default
    override func setUpWithError() throws { home = fm.temporaryDirectory.appendingPathComponent("FluentInstallerTests-" + UUID().uuidString); try fm.createDirectory(at: home, withIntermediateDirectories: true) }
    override func tearDownWithError() throws { try fm.removeItem(at: home) }
    private func app(_ location: URL, version: String, id: String = "org.fluentime.inputmethod.FluentIME") throws {
        try fm.createDirectory(at: location.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleVersion": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: location.appendingPathComponent("Contents/Info.plist"))
        let exe = location.appendingPathComponent("Contents/MacOS/FluentIME")
        try Data(version.utf8).write(to: exe); try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }
    private func learned(_ files: InstallationFiles) throws -> URL {
        let path = files.dictionary.appendingPathComponent("fluent.userdb/data")
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test learned words".utf8).write(to: path); return path
    }
    func testUpgradePreservesDictionaryAndBacksUpOldApplication() throws {
        let files = InstallationFiles(home: home), source = home.appendingPathComponent("download.app")
        try app(files.application, version: "old"); try app(source, version: "new")
        let words = try learned(files); try files.install(from: source)
        XCTAssertTrue(files.isInstalled); XCTAssertTrue(files.hasLocalDictionary)
        XCTAssertEqual(try String(contentsOf: words), "test learned words")
        XCTAssertEqual(try String(contentsOf: files.application.appendingPathComponent("Contents/MacOS/FluentIME")), "new")
        let backups = try fm.contentsOfDirectory(at: files.support.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].appendingPathComponent("Fluent IME.app/Contents/MacOS/FluentIME")), "old")
    }
    func testRepeatedUpgradesKeepOnlyTheNewestApplicationBackup() throws {
        let files = InstallationFiles(home: home)
        try app(files.application, version: "1")
        let unrelated = files.support.appendingPathComponent("Backups/0000-manual")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true); try Data().write(to: unrelated.appendingPathComponent("notes.txt"))
        for version in ["2", "3", "4"] {
            let source = home.appendingPathComponent("download-\(version).app"); try app(source, version: version)
            try files.install(from: source)
        }
        let backups = try fm.contentsOfDirectory(at: files.support.appendingPathComponent("Backups"), includingPropertiesForKeys: nil).filter { $0.lastPathComponent != "0000-manual" }
        XCTAssertEqual(backups.count, 1, "Updates must not accumulate one app copy each")
        XCTAssertEqual(try String(contentsOf: backups[0].appendingPathComponent("Fluent IME.app/Contents/MacOS/FluentIME")), "3")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path), "Folders the installer did not create stay")
    }
    func testInvalidPayloadDoesNotReplaceExistingInstallation() throws {
        let files = InstallationFiles(home: home), source = home.appendingPathComponent("unrelated.app")
        try app(files.application, version: "old"); try app(source, version: "bad", id: "another.app")
        XCTAssertThrowsError(try files.install(from: source))
        XCTAssertEqual(try String(contentsOf: files.application.appendingPathComponent("Contents/MacOS/FluentIME")), "old")
    }
    func testDictionaryResetRenamesAndStartsEmpty() throws {
        let files = InstallationFiles(home: home); let old = try learned(files)
        let backup = try XCTUnwrap(files.backupDictionary())
        XCTAssertFalse(fm.fileExists(atPath: old.path)); XCTAssertFalse(files.hasLocalDictionary)
        XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent("fluent.userdb/data")), "test learned words")
        XCTAssertTrue(fm.fileExists(atPath: files.dictionary.path))
    }
    func testUninstallKeepAndRemoveDataAndFailure() throws {
        for keep in [true, false] {
            let files = InstallationFiles(home: home.appendingPathComponent(String(keep)))
            try app(files.application, version: "new"); let words = try learned(files)
            XCTAssertThrowsError(try files.uninstall(keepData: keep) { _ in throw CocoaError(.fileWriteNoPermission) })
            XCTAssertTrue(fm.fileExists(atPath: words.path), "Failure must not delete user data")
            try files.uninstall(keepData: keep) { try fm.removeItem(at: $0) }
            XCTAssertFalse(files.isInstalled); XCTAssertEqual(fm.fileExists(atPath: words.path), keep)
        }
    }
    func testWritableInstallerCleanupCannotTargetInputMethod() throws {
        let installer = home.appendingPathComponent("Setup.app")
        try app(installer, version: "20", id: "org.fluentime.installer")
        XCTAssertEqual(try InstallerCleanup.target(installer: installer, readOnly: false).item.path, installer.path)
        let main = home.appendingPathComponent("Fluent IME.app"); try app(main, version: "20")
        XCTAssertThrowsError(try InstallerCleanup.target(installer: main, readOnly: false))
    }
    func testReadOnlyCleanupLeavesUnknownAndTranslocatedLocationsAlone() throws {
        let installer = home.appendingPathComponent("Setup.app")
        try app(installer, version: "20", id: "org.fluentime.installer")
        XCTAssertThrowsError(try InstallerCleanup.target(installer: installer, readOnly: true))
        let wrong: [String: Any] = ["images": [["image-path": "/tmp/other.dmg", "system-entities": [["mount-point": "/Volumes/Other"]]]]]
        XCTAssertThrowsError(try InstallerCleanup.target(installer: installer, readOnly: true, diskImages: wrong))
        XCTAssertTrue(fm.fileExists(atPath: installer.path))
    }
}
