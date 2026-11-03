import XCTest
import CryptoKit
@testable import FluentIMECore

final class UpdateTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(ReleaseVersion("v0.10.0")! > ReleaseVersion("0.9.99")!)
        XCTAssertEqual(ReleaseVersion("1.0"), ReleaseVersion("1.0.0"))
        for value in ["latest", "1.0-beta", "1..0", "-1.0", "1.0.0.9"] { XCTAssertNil(ReleaseVersion(value)) }
    }
    func testPrereleaseVersionsAndGitHubChannelFlags() throws {
        let versions = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (left, right) in zip(versions, versions.dropFirst()) { XCTAssertLessThan(ReleaseVersion(left)!, ReleaseVersion(right)!) }
        XCTAssertEqual(ReleaseVersion("1.0.0+build.2"), ReleaseVersion("1.0.0+build.9"))
        for invalid in ["1.0.0-", "1.0.0-beta..1", "1.0.0-01", "1.0.0+", "1.0.0+/file", "01.0.0", "1.0.0-测"] { XCTAssertNil(ReleaseVersion(invalid)) }
        // GitHub's flag, not a guessed tag spelling, determines the channel.
        let flagged = GitHubRelease(tag_name: "v1.1.0", draft: false, prerelease: true, assets: [])
        XCTAssertFalse(UpdateChannel.stable.accepts(flagged))
        XCTAssertTrue(UpdateChannel.preview.accepts(flagged))
        XCTAssertFalse(flagged.isNewer(than: "1.0.0"))
        XCTAssertTrue(flagged.isNewer(than: "1.0.0", channel: .preview))
        XCTAssertFalse(UpdateChannel.preview.accepts(GitHubRelease(tag_name: "v2.0.0", draft: true, prerelease: true, assets: [])))
        let final = GitHubRelease(tag_name: "v1.0.0", draft: false, prerelease: false, assets: [])
        XCTAssertTrue(final.isNewer(than: "1.0.0-rc.1"))
        XCTAssertFalse(final.isNewer(than: "1.1.0-beta.1"), "Returning to stable must not offer a downgrade")
    }
    func testChannelHistorySortsVersionsAndKeepsReleaseNotes() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ChannelReleaseProtocol.self]
        let service = GitHubUpdateService(edition: .lite, configuration: configuration)
        let stable = try await service.history(channel: .stable)
        XCTAssertEqual(stable.map(\.version), ["1.0.0", "0.9.0"])
        let preview = try await service.history(channel: .preview)
        XCTAssertEqual(preview.map(\.version), ["1.1.0-beta.2", "1.1.0-beta.1", "1.0.0", "0.9.0"])
        XCTAssertEqual(preview.first?.body, "## Changes\n- Fixed selection.")
        XCTAssertEqual(preview.first?.published_at, "2026-11-02T00:00:00Z")
        let latest = try await service.latest(channel: .preview)
        XCTAssertEqual(latest?.version, "1.1.0-beta.1", "Skip releases without this edition's installer")
        XCTAssertEqual(latest?.pageURL.absoluteString, "https://github.com/egysoloman/Fluent-IME/releases/tag/v1.1.0-beta.1")
        let limited = URLSessionConfiguration.ephemeral; limited.protocolClasses = [RateLimitedReleaseProtocol.self]
        do { _ = try await GitHubUpdateService(edition: .lite, configuration: limited).latest(channel: .preview); XCTFail("A failed preview lookup must not silently switch to stable") }
        catch { XCTAssertTrue(error is UpdateError) }
    }
    func testHistoryUsesCacheAndPublicFeedWhenTheAPIQuotaIsExhausted() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [QuotaReleaseProtocol.self]
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-History-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: cache) }
        // No cache: the feed supplies notes; versions newer than the latest stable stay in the test channel.
        QuotaReleaseProtocol.mode = .limited
        let service = GitHubUpdateService(edition: .lite, configuration: configuration, cache: cache)
        let stable = try await service.history(channel: .stable)
        XCTAssertEqual(stable.map(\.version), ["0.6.5", "0.6.4"])
        XCTAssertEqual(stable.first?.name, "Fluent IME 0.6.5")
        XCTAssertEqual(stable.first?.body, "## Changes\n- Rows move one at a time & keep <numbers>.\nDefault download.")
        let versions1 = try await service.history(channel: .preview).map(\.version)
        XCTAssertEqual(versions1, ["0.7.0-beta.1", "0.6.6", "0.6.5", "0.6.4"])
        do { _ = try await service.latest(channel: .preview); XCTFail("The feed has no assets and cannot prove there is no newer preview") }
        catch { XCTAssertTrue(error is UpdateError) }
        // A successful response is cached; the next request is conditional and a 304 reuses it.
        QuotaReleaseProtocol.mode = .available
        let versions2 = try await service.history(channel: .stable).map(\.version)
        XCTAssertEqual(versions2, ["1.0.0"])
        QuotaReleaseProtocol.mode = .notModified
        let versions3 = try await service.history(channel: .stable).map(\.version)
        XCTAssertEqual(versions3, ["1.0.0"])
        XCTAssertEqual(QuotaReleaseProtocol.lastETag, "\"v1\"")
        QuotaReleaseProtocol.mode = .limited
        let versions4 = try await service.history(channel: .stable).map(\.version)
        XCTAssertEqual(versions4, ["1.0.0"], "An exhausted quota shows the cached list")
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
        let names = ["Fluent-IME-0.6.0-Setup.dmg", "Fluent-IME-0.6.0-Full-Setup.dmg", "Fluent-IME-0.6.0-Update-Setup.dmg", "release.json", "release-full.json", "release-update.json"]
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v0.6.0", "draft": false, "prerelease": false, "assets": names.map { ["name": $0, "size": 8, "browser_download_url": "https://github.com/egysoloman/Fluent-IME/releases/download/v0.6.0/" + $0] }])
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        XCTAssertEqual(release.installer(for: .lite)?.name, names[0])
        XCTAssertEqual(release.installer(for: .full)?.name, names[1])
        XCTAssertEqual(release.installer(for: .update)?.name, names[2])
        XCTAssertEqual(release.manifest(for: .lite)?.name, names[3])
        XCTAssertEqual(release.manifest(for: .full)?.name, names[4])
        XCTAssertEqual(release.manifest(for: .update)?.name, names[5])
    }
    func testWebsiteFallbackRejectsUntrustedAndNonReleaseRedirects() {
        XCTAssertEqual(GitHubUpdateService.releaseTag(from: URL(string: "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2")!), "v0.6.2")
        for value in [
            "https://github.com/other/Fluent-IME/releases/tag/v0.6.2",
            "https://github.com/egysoloman/Fluent-IME/releases/latest",
            "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2-",
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
            XCTAssertEqual(release?.name, "Fluent IME 0.6.2")
            XCTAssertEqual(release?.body, "- Notes come from the public feed.", "The quota fallback must still show release notes")
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
        } else if url.path.hasSuffix("/releases.atom") {
            body = Data(#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><entry><updated>2026-11-01T00:00:00Z</updated><link rel="alternate" type="text/html" href="https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.2"/><title>Fluent IME 0.6.2</title><content type="html">&lt;ul&gt;&lt;li&gt;Notes come from the public feed.&lt;/li&gt;&lt;/ul&gt;</content></entry></feed>"#.utf8)
        } else { return fail() }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badURL)) }
    override func stopLoading() {}
}

private final class ChannelReleaseProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let records: [(String, Bool, Bool)] = [("0.9.0", false, false), ("1.1.0-beta.1", true, false), ("1.0.0", false, false), ("1.1.0-beta.2", true, false), ("9.0.0", true, true), ("nightly", true, false)]
        let json = records.map { version, preview, draft -> [String: Any] in
            let base = "https://github.com/egysoloman/Fluent-IME/releases/download/v" + version + "/"
            return ["tag_name": "v" + version, "prerelease": preview, "draft": draft,
                "body": "## Changes\n- Fixed selection.", "published_at": "2026-11-02T00:00:00Z",
                "assets": version == "1.1.0-beta.2" ? [] : ["Fluent-IME-" + version + "-Setup.dmg", "release.json"].map { ["name": $0, "size": 10, "browser_download_url": base + $0] }]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class QuotaReleaseProtocol: URLProtocol {
    enum Mode { case limited, available, notModified }
    nonisolated(unsafe) static var mode = Mode.limited
    nonisolated(unsafe) static var lastETag: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var responseURL = url, status = 200, body = Data(), headers: [String: String] = [:]
        if url.host == "api.github.com" {
            Self.lastETag = request.value(forHTTPHeaderField: "If-None-Match")
            switch Self.mode {
            case .limited: status = 403
            case .notModified: status = Self.lastETag == "\"v1\"" ? 304 : 500
            case .available:
                headers["ETag"] = "\"v1\""
                body = try! JSONSerialization.data(withJSONObject: [["tag_name": "v1.0.0", "draft": false, "prerelease": false, "assets": []]])
            }
        } else if url.path.hasSuffix("/releases/latest") {
            responseURL = URL(string: "https://github.com/egysoloman/Fluent-IME/releases/tag/v0.6.5")!
        } else if url.path.hasSuffix("/releases.atom") {
            let entries = ["0.7.0-beta.1", "0.6.6", "0.6.5", "0.6.4"].map { version in
                """
                <entry><id>tag:github.com,2008:Repository/1/v\(version)</id><updated>2026-11-02T04:46:50Z</updated>
                <link rel="alternate" type="text/html" href="https://github.com/egysoloman/Fluent-IME/releases/tag/v\(version)"/>
                <title>Fluent IME \(version)</title>
                <content type="html">&lt;h2&gt;Changes&lt;/h2&gt;&lt;ul&gt;&lt;li&gt;Rows move one at a time &amp;amp; keep &amp;lt;numbers&amp;gt;.&lt;/li&gt;&lt;/ul&gt;&lt;p&gt;Default download.&lt;/p&gt;</content></entry>
                """
            }
            body = Data(("<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Release notes</title>" + entries.joined() + "</feed>").utf8)
        } else { status = 404 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
