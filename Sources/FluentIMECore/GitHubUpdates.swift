import Foundation
import CryptoKit

public enum ReleaseEdition: String, Decodable {
    case lite, full
    public static var current: Self {
        if let value = Bundle.main.object(forInfoDictionaryKey: "FluentIMEEdition") as? String, let edition = Self(rawValue: value) { return edition }
        return Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Models/ChineseContextScorer.mlmodelc").path) } == true ? .full : .lite
    }
}

public struct ReleaseVersion: Comparable, Equatable {
    private let parts: [Int]
    public init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let strings = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(strings.count), strings.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), strings.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = strings.map { Int($0)! } + Array(repeating: 0, count: 3 - strings.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}
public struct GitHubRelease: Decodable {
    public struct Asset: Decodable {
        public let name: String
        public let size: Int64
        public let browser_download_url: URL
        public let digest: String?
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    public var installer: Asset? { installer(for: .lite) }
    public var manifest: Asset? { manifest(for: .lite) }
    public func installer(for edition: ReleaseEdition) -> Asset? { assets.first { $0.name == "Fluent-IME-\(version)\(edition == .full ? "-Full" : "")-Setup.dmg" } }
    public func manifest(for edition: ReleaseEdition) -> Asset? { assets.first { $0.name == (edition == .full ? "release-full.json" : "release.json") } }
    public func isNewer(than current: String) -> Bool {
        guard !draft, !prerelease, let next = ReleaseVersion(version), let old = ReleaseVersion(current) else { return false }
        return next > old
    }
}
public enum UpdateError: Error, LocalizedError {
    case unavailable, invalidRelease, incompatible, integrity
    public var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.updateUnavailable
        case .invalidRelease: return L10n.updateInvalid
        case .incompatible: return L10n.updateIncompatible
        case .integrity: return L10n.updateIntegrity
        }
    }
}
private final class UpdateTransport: NSObject, URLSessionDownloadDelegate {
    let limit: Int64
    init(limit: Int64 = 2_000_000_000) { self.limit = limit }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        completionHandler(request.url?.scheme == "https" && (host == "github.com" || host.hasSuffix(".githubusercontent.com")) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesWritten > limit { downloadTask.cancel() } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
/// Checks only the project's public releases; never sends input or clipboard data.
public final class GitHubUpdateService {
    public static let repository = "egysoloman/Fluent-IME"
    public static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    private let transport = UpdateTransport()
    private let edition: ReleaseEdition
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
    }()
    public convenience init(edition: ReleaseEdition = .current) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800
        config.httpAdditionalHeaders = ["User-Agent": "Fluent-IME-Updater", "Accept": "application/vnd.github+json"]
        self.init(edition: edition, configuration: config)
    }
    init(edition: ReleaseEdition, configuration: URLSessionConfiguration) {
        self.edition = edition; self.configuration = configuration
    }
    public static func trustedAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil && url.path.hasPrefix("/\(repository)/releases/download/")
    }
    public func latest() async throws -> GitHubRelease? {
        let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
        let result: (Data, URLResponse)
        do { result = try await session.data(from: url) }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            return try await latestFromWebsite()
        }
        try Task.checkCancellation()
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { return nil }
        // Anonymous API quotas are shared by everyone behind the same network.
        // The public release redirect and assets do not consume that quota.
        if status == 403 || status == 429 || status.map({ (500...599).contains($0) }) == true {
            return try await latestFromWebsite()
        }
        guard status == 200, data.count < 2_000_000 else { throw UpdateError.unavailable }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard ReleaseVersion(release.version) != nil, !release.draft, !release.prerelease else { throw UpdateError.invalidRelease }
        return release
    }
    private func latestFromWebsite() async throws -> GitHubRelease? {
        var request = URLRequest(url: Self.releasesURL.appendingPathComponent("latest"))
        request.httpMethod = "HEAD"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let url = response.url, let tag = Self.releaseTag(from: url) else { throw UpdateError.unavailable }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let base = Self.releasesURL.appendingPathComponent("download").appendingPathComponent(tag)
        let manifestName = edition == .full ? "release-full.json" : "release.json"
        let manifestURL = base.appendingPathComponent(manifestName)
        let (data, manifestResponse) = try await session.data(from: manifestURL)
        guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200, data.count < 100_000 else { throw UpdateError.invalidRelease }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        guard manifest.version == version, manifest.edition == edition,
              manifest.installer.dmg_sha256.count == 64,
              manifest.installer.dmg_sha256.allSatisfy(\.isHexDigit) else { throw UpdateError.invalidRelease }
        let installerName = "Fluent-IME-\(version)\(edition == .full ? "-Full" : "")-Setup.dmg"
        let installerURL = base.appendingPathComponent(installerName)
        request = URLRequest(url: installerURL); request.httpMethod = "HEAD"
        let (_, installerResponse) = try await session.data(for: request)
        try Task.checkCancellation()
        let size = installerResponse.expectedContentLength
        guard (installerResponse as? HTTPURLResponse)?.statusCode == 200,
              (1...2_000_000_000).contains(size) else { throw UpdateError.invalidRelease }
        return GitHubRelease(tag_name: tag, draft: false, prerelease: false, assets: [
            .init(name: manifestName, size: Int64(data.count), browser_download_url: manifestURL, digest: nil),
            .init(name: installerName, size: size, browser_download_url: installerURL, digest: "sha256:" + manifest.installer.dmg_sha256)
        ])
    }
    static func releaseTag(from url: URL) -> String? {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let prefix = "/\(repository)/releases/tag/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let tag = String(url.path.dropFirst(prefix.count))
        return ReleaseVersion(tag) == nil ? nil : tag
    }
    public func download(_ release: GitHubRelease, to directory: URL) async throws -> URL {
        guard let asset = release.installer(for: edition), let manifest = release.manifest(for: edition),
              Self.trustedAsset(asset.browser_download_url), Self.trustedAsset(manifest.browser_download_url),
              (1...2_000_000_000).contains(asset.size), manifest.size < 100_000 else { throw UpdateError.invalidRelease }
        let (metadata, response) = try await session.data(from: manifest.browser_download_url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, metadata.count < 100_000 else { throw UpdateError.invalidRelease }
        let info = try JSONDecoder().decode(UpdateManifest.self, from: metadata)
        guard info.edition == edition else { throw UpdateError.invalidRelease }
        try info.validate(release: release)
        let transport = UpdateTransport(limit: asset.size)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 1800
        let downloadSession = URLSession(configuration: config, delegate: transport, delegateQueue: nil)
        defer { downloadSession.finishTasksAndInvalidate() }
        let (temporary, result) = try await downloadSession.download(from: asset.browser_download_url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        try Self.verify(file: temporary, expectedSize: asset.size, sha256: info.installer.dmg_sha256)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
    public static func verify(file: URL, expectedSize: Int64, sha256: String) throws {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value == expectedSize else { throw UpdateError.integrity }
        let stream = try FileHandle(forReadingFrom: file); defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw UpdateError.integrity }
    }
}
public struct UpdateManifest: Decodable {
    public struct Installer: Decodable { public let dmg_sha256: String }
    public let version: String
    public let minimum_macos: String
    public let architecture: String
    public let edition: ReleaseEdition
    public let installer: Installer
    public func validate(release: GitHubRelease) throws {
        guard version == release.version else { throw UpdateError.invalidRelease }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let current = ProcessInfo.processInfo.operatingSystemVersion
        guard architecture == arch, let required = ReleaseVersion(minimum_macos), let running = ReleaseVersion("\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"), running >= required else { throw UpdateError.incompatible }
    }
}
