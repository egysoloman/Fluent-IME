import XCTest
import CryptoKit
@testable import FluentIMECore

final class UpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.99")!)
        XCTAssertEqual(ReleaseVersion("1.0"), ReleaseVersion("1.0.0"))
        for value in ["latest", "1.0-beta", "1..0", "-1.0", "1.0.0.9"] { XCTAssertNil(ReleaseVersion(value)) }
    }
    func testReleaseFilteringAndAssetSelection() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(#"{"tag_name":"v0.6.0","draft":false,"prerelease":false,"assets":[{"name":"Fluent-IME-0.6.0-Setup.dmg","size":8,"browser_download_url":"https://github.com/egysoloman/Fluent-IME/releases/download/v0.6.0/Fluent-IME-0.6.0-Setup.dmg"}]}"#.utf8))
        XCTAssertTrue(release.isNewer(than: "0.5.4")); XCTAssertFalse(release.isNewer(than: "0.6.0"))
        XCTAssertNotNil(release.installer)
        XCTAssertNil(release.manifest)
    }
    func testOnlyProjectReleaseAssetsAreAccepted() {
        XCTAssertTrue(GitHubUpdateService.trustedAsset(URL(string: "https://github.com/egysoloman/Fluent-IME/releases/download/v0.6.0/a.dmg")!))
        for value in ["http://github.com/egysoloman/Fluent-IME/releases/download/a", "https://github.com/other/Fluent-IME/releases/download/a", "https://github.com.example.com/egysoloman/Fluent-IME/releases/download/a", "https://user:secret@github.com/egysoloman/Fluent-IME/releases/download/a"] { XCTAssertFalse(GitHubUpdateService.trustedAsset(URL(string: value)!)) }
    }
    func testEditionsSelectSeparateInstallersAndManifests() throws {
        let names = ["Fluent-IME-0.6.0-Setup.dmg", "Fluent-IME-0.6.0-Full-Setup.dmg", "release.json", "release-full.json"]
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v0.6.0", "draft": false, "prerelease": false, "assets": names.map { ["name": $0, "size": 8, "browser_download_url": "https://github.com/egysoloman/Fluent-IME/releases/download/v0.6.0/" + $0] }])
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        XCTAssertEqual(release.installer(for: .lite)?.name, names[0])
        XCTAssertEqual(release.installer(for: .full)?.name, names[1])
        XCTAssertEqual(release.manifest(for: .lite)?.name, names[2])
        XCTAssertEqual(release.manifest(for: .full)?.name, names[3])
    }
    func testChecksumAndSizeRejectCorruptedDownloads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("installer fixture".utf8); try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try GitHubUpdateService.verify(file: file, expectedSize: Int64(data.count), sha256: digest))
        XCTAssertThrowsError(try GitHubUpdateService.verify(file: file, expectedSize: Int64(data.count + 1), sha256: digest))
        XCTAssertThrowsError(try GitHubUpdateService.verify(file: file, expectedSize: Int64(data.count), sha256: String(repeating: "0", count: 64)))
        try Data("modified installer".utf8).write(to: file)
        XCTAssertThrowsError(try GitHubUpdateService.verify(file: file, expectedSize: Int64(data.count), sha256: digest))
    }
}
