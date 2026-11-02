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
    func testWebsiteFallbackRejectsUntrustedAndNonReleaseRedirects() {
        XCTAssertEqual(GitHubUpdateService.releaseTag(from: URL(string: "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2")!), "v0.6.2")
        for value in [
            "https://github.com/other/Fluent-IME/releases/tag/v0.6.2",
            "https://github.com/egysoloman/Fluent-IME/releases/latest",
            "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2-beta",
            "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2/extra",
            "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2?asset=other",
            "http://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2",
            "https://user@github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2"
        ] { XCTAssertNil(GitHubUpdateService.releaseTag(from: URL(string: value)!)) }
    }
    func testAPIQuotaFallbackKeepsEditionAndChecksum() async throws {
        for edition in [ReleaseEdition.lite, .full] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RateLimitedReleaseProtocol.self]
            let service = GitHubUpdateService(edition: edition, configuration: config)
            let release = try await service.latest()
            XCTAssertEqual(release?.version, "0.6.2")
            XCTAssertEqual(release?.installer(for: edition)?.size, 123456)
            XCTAssertEqual(release?.installer(for: edition)?.digest, "sha256:" + String(repeating: "a", count: 64))
            XCTAssertEqual(release?.manifest(for: edition)?.name, edition == .full ? "release-full.json" : "release.json")
            XCTAssertNotNil(release?.installer(for: edition))
            XCTAssertNil(release?.installer(for: edition == .full ? .lite : .full))
        }
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
    func testDownloadReportsActualBytesBeforeVerification() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DownloadFixtureProtocol.self]
        let service = GitHubUpdateService(edition: .lite, configuration: config)
        let data = DownloadFixtureProtocol.payload
        let base = "https://github.com/egysoloman/Fluent-IME/releases/download/v99.0.0/"
        let release = try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: [
            "tag_name": "v99.0.0", "draft": false, "prerelease": false,
            "assets": [["name": "release.json", "size": 300, "browser_download_url": base + "release.json"],
                       ["name": "Fluent-IME-99.0.0-Setup.dmg", "size": data.count, "browser_download_url": base + "Fluent-IME-99.0.0-Setup.dmg"]]
        ]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        final class Reports: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [UpdateDownloadProgress] = []
            func append(_ progress: UpdateDownloadProgress) { lock.lock(); defer { lock.unlock() }; values.append(progress) }
            func snapshot() -> [UpdateDownloadProgress] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let reports = Reports()
        let file = try await service.download(release, to: directory) { reports.append($0) }
        XCTAssertEqual(try Data(contentsOf: file), data)
        let receipt = try JSONDecoder().decode(VerifiedUpdateReceipt.self, from: Data(contentsOf: directory.appendingPathComponent(VerifiedUpdateReceipt.filename)))
        XCTAssertEqual(receipt.version, release.version)
        XCTAssertEqual(receipt.size, Int64(data.count))
        XCTAssertNoThrow(try GitHubUpdateService.verify(file: file, expectedSize: receipt.size, sha256: receipt.sha256))
        let values = reports.snapshot()
        XCTAssertEqual(values.first, .downloading(received: 0, total: Int64(data.count)))
        XCTAssertEqual(values.last, .verifying)
        let received = values.compactMap { value -> Int64? in
            guard case .downloading(let bytes, let total) = value else { return nil }
            XCTAssertEqual(total, Int64(data.count)); return bytes
        }
        XCTAssertEqual(received.last, Int64(data.count))
        XCTAssertEqual(received, received.sorted())
    }
    func testCancellingTransferDoesNotProduceAnInstaller() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SlowDownloadFixtureProtocol.self]
        let service = GitHubUpdateService(edition: .lite, configuration: config)
        let base = "https://github.com/egysoloman/Fluent-IME/releases/download/v99.0.0/"
        let release = try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: [
            "tag_name": "v99.0.0", "draft": false, "prerelease": false,
            "assets": [["name": "release.json", "size": 300, "browser_download_url": base + "release.json"],
                       ["name": "Fluent-IME-99.0.0-Setup.dmg", "size": DownloadFixtureProtocol.payload.count, "browser_download_url": base + "Fluent-IME-99.0.0-Setup.dmg"]]
        ]))
        let started = expectation(description: "received first chunk")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let download = Task {
            try await service.download(release, to: directory) { progress in
                if case .downloading(let bytes, _) = progress, bytes > 0 { started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 3)
        download.cancel()
        do { _ = try await download.value; XCTFail("Cancelled transfer succeeded") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

private class DownloadFixtureProtocol: URLProtocol {
    static let payload = Data(repeating: 0x5a, count: 262144)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, body: Data
        if url.pathExtension == "json" {
            body = try! JSONSerialization.data(withJSONObject: ["version": "99.0.0", "minimum_macos": "13.0", "architecture": "arm64", "edition": "lite", "installer": ["dmg_sha256": SHA256.hash(data: Self.payload).map { String(format: "%02x", $0) }.joined()]])
        } else { body = Self.payload }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: body.count, by: 65536) { client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + 65536, body.count))) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class SlowDownloadFixtureProtocol: DownloadFixtureProtocol {
    override func startLoading() {
        guard let url = request.url, url.pathExtension == "dmg" else { super.startLoading(); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(Self.payload.count)])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload.prefix(65536))
        // Leave the transfer open until the test cancels it.
    }
}

/// Simulates a shared-IP quota without using credentials or GitHub's network.
private final class RateLimitedReleaseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var responseURL = url, status = 200, body = Data(), headers: [String: String] = [:]
        if url.host == "api.github.com" { status = 403 }
        else if url.path.hasSuffix("/releases/latest") {
            guard request.httpMethod == "HEAD" else { return fail() }
            responseURL = URL(string: "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2")!
        } else if ["release.json", "release-full.json"].contains(url.lastPathComponent) {
            let edition = url.lastPathComponent == "release-full.json" ? "full" : "lite"
            body = try! JSONSerialization.data(withJSONObject: ["version": "0.6.2", "minimum_macos": "13.0", "architecture": "arm64", "edition": edition, "installer": ["dmg_sha256": String(repeating: "a", count: 64)]])
        } else if url.pathExtension == "dmg" {
            guard request.httpMethod == "HEAD" else { return fail() }
            headers["Content-Length"] = "123456"
        } else { return fail() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
    override func stopLoading() {}
}
