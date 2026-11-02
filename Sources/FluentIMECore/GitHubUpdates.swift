import Foundation
import CryptoKit

public enum ReleaseEdition: String, Codable {
    case lite, full
    public static var current: Self {
        if let value = Bundle.main.object(forInfoDictionaryKey: "FluentIMEEdition") as? String, let edition = Self(rawValue: value) { return edition }
        return Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Models/ChineseContextScorer.mlmodelc").path) } == true ? .full : .lite
    }
}

public enum UpdateChannel: String, CaseIterable, Codable {
    case stable, preview
    public var title: String { self == .stable ? L10n.updateChannelStable : L10n.updateChannelPreview }
    public func accepts(_ release: GitHubRelease) -> Bool {
        guard !release.draft, ReleaseVersion(release.version) != nil else { return false }
        return self == .preview || !release.prerelease
    }
}

public struct ReleaseVersion: Comparable, Equatable {
    private let parts: [Int]
    private let prerelease: [String]
    public var isPrerelease: Bool { !prerelease.isEmpty }
    public init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let metadata = value.split(separator: "+", omittingEmptySubsequences: false)
        func identifiers(_ text: Substring) -> [String]? {
            let ids = text.split(separator: ".", omittingEmptySubsequences: false)
            guard ids.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } }) else { return nil }
            return ids.map(String.init)
        }
        guard metadata.count <= 2, metadata.count == 1 || identifiers(metadata[1]) != nil else { return nil }
        let components = metadata[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let strings = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(strings.count), strings.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || $0.first != "0") && Int($0) != nil }) else { return nil }
        if components.count == 2 {
            guard strings.count == 3, let ids = identifiers(components[1]), ids.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0.count == 1 || $0.first != "0" }) else { return nil }
            prerelease = ids
        } else { prerelease = [] }
        parts = strings.map { Int($0)! } + Array(repeating: 0, count: 3 - strings.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.parts != rhs.parts { return lhs.parts.lexicographicallyPrecedes(rhs.parts) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let ln = left.allSatisfy(\.isNumber), rn = right.allSatisfy(\.isNumber)
            if ln != rn { return ln }
            if ln && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
public struct GitHubRelease: Codable {
    public struct Asset: Codable {
        public let name: String
        public let size: Int64
        public let browser_download_url: URL
        public let digest: String?
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public let name: String?
    public let body: String?
    public let published_at: String?
    public init(tag_name: String, draft: Bool, prerelease: Bool, assets: [Asset], name: String? = nil, body: String? = nil, published_at: String? = nil) {
        self.tag_name = tag_name; self.draft = draft; self.prerelease = prerelease; self.assets = assets
        self.name = name; self.body = body; self.published_at = published_at
    }
    public var pageURL: URL { GitHubUpdateService.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag_name) }
    public var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    public var installer: Asset? { installer(for: .lite) }
    public var manifest: Asset? { manifest(for: .lite) }
    public func installer(for edition: ReleaseEdition) -> Asset? { assets.first { $0.name == "Fluent-IME-\(version)\(edition == .full ? "-Full" : "")-Setup.dmg" } }
    public func manifest(for edition: ReleaseEdition) -> Asset? { assets.first { $0.name == (edition == .full ? "release-full.json" : "release.json") } }
    public func isNewer(than current: String, channel: UpdateChannel = .stable) -> Bool {
        guard channel.accepts(self), let next = ReleaseVersion(version), let old = ReleaseVersion(current) else { return false }
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
public enum UpdateDownloadProgress: Equatable {
    case downloading(received: Int64, total: Int64)
    case verifying
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

/// Stream to a private temporary file. The serial delegate queue owns file I/O and
/// byte counts; only cancellation and continuation ownership cross queue boundaries.
private final class UpdateFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int64
    private let progress: (@Sendable (UpdateDownloadProgress) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var cancelled = false
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-Update-" + UUID().uuidString)
    private var output: FileHandle?
    private var response: URLResponse?
    private var failure: Error?
    private var received: Int64 = 0
    private var lastReport: TimeInterval = 0
    init(limit: Int64, progress: (@Sendable (UpdateDownloadProgress) -> Void)?) { self.limit = limit; self.progress = progress }
    func fetch(_ url: URL, configuration: URLSessionConfiguration) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw UpdateError.unavailable }
                    output = try FileHandle(forWritingTo: file)
                } catch { try? FileManager.default.removeItem(at: file); continuation.resume(throwing: error); return }
                lock.lock()
                if cancelled {
                    lock.unlock(); try? output?.close(); output = nil; try? FileManager.default.removeItem(at: file)
                    continuation.resume(throwing: CancellationError()); return
                }
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: url)
                self.task = task; self.continuation = continuation
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        completionHandler(request.url?.scheme == "https" && (host == "github.com" || host.hasSuffix(".githubusercontent.com")) ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= limit else {
            failure = UpdateError.unavailable; completionHandler(.cancel); return
        }
        self.response = response; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard received + Int64(data.count) <= limit, let output else { throw UpdateError.integrity }
            try output.write(contentsOf: data); received += Int64(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.08 || received == limit {
                lastReport = now; progress?(.downloading(received: received, total: limit))
            }
        } catch { failure = error; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do { try output?.close() } catch { failure = failure ?? error }; output = nil
        lock.lock(); let continuation = continuation; self.continuation = nil; self.task = nil; let cancelled = cancelled; lock.unlock()
        defer { session.finishTasksAndInvalidate() }
        if let error = failure ?? error ?? (cancelled ? CancellationError() : nil) {
            try? FileManager.default.removeItem(at: file); continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (file, response))
        } else {
            try? FileManager.default.removeItem(at: file); continuation?.resume(throwing: UpdateError.unavailable)
        }
    }
}
/// Checks only the project's public releases; never sends input or clipboard data.
public final class GitHubUpdateService {
    public static let repository = "egysoloman/Fluent-IME"
    public static let releasesURL = URL(string: "https://github.com/\(repository)/releases")!
    private let transport = UpdateTransport()
    private let edition: ReleaseEdition
    private let configuration: URLSessionConfiguration
    private let cache: URL?
    private lazy var session: URLSession = {
        URLSession(configuration: configuration, delegate: transport, delegateQueue: nil)
    }()
    public convenience init(edition: ReleaseEdition = .current) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 1800
        config.httpAdditionalHeaders = ["User-Agent": "Fluent-IME-Updater", "Accept": "application/vnd.github+json"]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.init(edition: edition, configuration: config, cache: caches?.appendingPathComponent("org.fluentime.inputmethod.FluentIME/release-history.json"))
    }
    init(edition: ReleaseEdition, configuration: URLSessionConfiguration, cache: URL? = nil) {
        self.edition = edition; self.configuration = configuration; self.cache = cache
    }
    public static func trustedAsset(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil && url.path.hasPrefix("/\(repository)/releases/download/")
    }
    public func history(channel: UpdateChannel) async throws -> [GitHubRelease] {
        try await releases().filter { channel.accepts($0) }.sorted { ReleaseVersion($0.version)! > ReleaseVersion($1.version)! }
    }
    public func latest(channel: UpdateChannel) async throws -> GitHubRelease? {
        if channel == .stable { return try await latest() }
        let records = try await history(channel: channel)
        // The public feed has no assets, so it cannot prove there is no newer preview.
        if !records.isEmpty, records.allSatisfy({ $0.assets.isEmpty }) { throw UpdateError.unavailable }
        return records.first { $0.installer(for: edition) != nil && $0.manifest(for: edition) != nil }
    }
    private struct CachedReleases: Codable { let etag: String; let data: Data }
    /// The anonymous API allows 60 requests an hour per network. A conditional
    /// request answered with 304 does not count, and the cached list or the public
    /// release feed covers an exhausted quota.
    private func releases() async throws -> [GitHubRelease] {
        let cached = cache.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(CachedReleases.self, from: $0) }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=30")!)
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let status: Int?, data: Data, response: URLResponse?
        do { (data, response) = try await session.data(for: request); status = (response as? HTTPURLResponse)?.statusCode }
        catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            if let cached { return try JSONDecoder().decode([GitHubRelease].self, from: cached.data) }
            throw error
        }
        try Task.checkCancellation()
        if status == 304, let cached { return try JSONDecoder().decode([GitHubRelease].self, from: cached.data) }
        if status == 200, data.count < 4_000_000 {
            let records = try JSONDecoder().decode([GitHubRelease].self, from: data)
            if let cache, let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
               let encoded = try? JSONEncoder().encode(CachedReleases(etag: etag, data: data)) {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? encoded.write(to: cache, options: .atomic)
            }
            return records
        }
        if let cached { return try JSONDecoder().decode([GitHubRelease].self, from: cached.data) }
        guard status == 403 || status == 429 || status.map({ (500...599).contains($0) }) == true else { throw UpdateError.unavailable }
        return try await releasesFromFeed()
    }
    private func feedEntries() async throws -> [ReleaseFeed.Entry] {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: Self.releasesURL.appendingPathExtension("atom")) }
        catch { try Task.checkCancellation(); throw (error as? URLError)?.code == .cancelled ? error : UpdateError.unavailable }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000,
              let entries = ReleaseFeed.entries(data) else { throw UpdateError.unavailable }
        return entries
    }
    private func releasesFromFeed() async throws -> [GitHubRelease] {
        let entries = try await feedEntries()
        // The feed has no Pre-release flag. Anything newer than the latest stable
        // release, or with a prerelease version, stays in the test channel.
        let stable = (try? await latestStableTag()).flatMap { ReleaseVersion($0) }
        return entries.compactMap { entry in
            guard let version = ReleaseVersion(entry.tag) else { return nil }
            let prerelease = version.isPrerelease || stable.map { version > $0 } ?? false
            return GitHubRelease(tag_name: entry.tag, draft: false, prerelease: prerelease, assets: [], name: entry.title, body: entry.notes, published_at: entry.updated)
        }
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
        guard UpdateChannel.stable.accepts(release) else { throw UpdateError.invalidRelease }
        return release
    }
    /// The public redirect from /releases/latest names the newest stable tag.
    private func latestStableTag() async throws -> String? {
        var request = URLRequest(url: Self.releasesURL.appendingPathComponent("latest"))
        request.httpMethod = "HEAD"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (_, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let url = response.url, let tag = Self.releaseTag(from: url) else { throw UpdateError.unavailable }
        return tag
    }
    private func latestFromWebsite() async throws -> GitHubRelease? {
        guard let tag = try await latestStableTag() else { return nil }
        var request: URLRequest
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
        // Release notes are optional here; the feed is outside the API quota as well.
        let entry = (try? await feedEntries())?.first { $0.tag == tag }
        try Task.checkCancellation()
        return GitHubRelease(tag_name: tag, draft: false, prerelease: false, assets: [
            .init(name: manifestName, size: Int64(data.count), browser_download_url: manifestURL, digest: nil),
            .init(name: installerName, size: size, browser_download_url: installerURL, digest: "sha256:" + manifest.installer.dmg_sha256)
        ], name: entry?.title, body: entry?.notes, published_at: entry?.updated)
    }
    static func releaseTag(from url: URL) -> String? {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let prefix = "/\(repository)/releases/tag/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let tag = String(url.path.dropFirst(prefix.count))
        return ReleaseVersion(tag) == nil ? nil : tag
    }
    public func download(_ release: GitHubRelease, to directory: URL, progress: (@Sendable (UpdateDownloadProgress) -> Void)? = nil) async throws -> URL {
        guard let asset = release.installer(for: edition), let manifest = release.manifest(for: edition),
              Self.trustedAsset(asset.browser_download_url), Self.trustedAsset(manifest.browser_download_url),
              (1...2_000_000_000).contains(asset.size), manifest.size < 100_000 else { throw UpdateError.invalidRelease }
        let (metadata, response) = try await session.data(from: manifest.browser_download_url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, metadata.count < 100_000 else { throw UpdateError.invalidRelease }
        let info = try JSONDecoder().decode(UpdateManifest.self, from: metadata)
        guard info.edition == edition else { throw UpdateError.invalidRelease }
        try info.validate(release: release)
        progress?(.downloading(received: 0, total: asset.size))
        let transfer = UpdateFileTransfer(limit: asset.size, progress: progress)
        let config = configuration.copy() as! URLSessionConfiguration; config.timeoutIntervalForResource = 1800
        let (temporary, result) = try await transfer.fetch(asset.browser_download_url, configuration: config)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (result as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unavailable }
        try Task.checkCancellation()
        progress?(.verifying)
        try Self.verify(file: temporary, expectedSize: asset.size, sha256: info.installer.dmg_sha256)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: temporary, to: target)
        do { try VerifiedUpdateReceipt(version: release.version, edition: edition, size: asset.size, sha256: info.installer.dmg_sha256).save(beside: target) }
        catch { try? FileManager.default.removeItem(at: target); throw error }
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

/// Reads GitHub's public release feed, which is not subject to the API quota.
enum ReleaseFeed {
    struct Entry { var tag = "", title = "", updated = "", notes = "" }
    static func entries(_ data: Data) -> [Entry]? {
        final class Reader: NSObject, XMLParserDelegate {
            var entries: [Entry] = [], entry: Entry?, text = ""
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
                text = ""
                if name == "entry" { entry = Entry() }
                if name == "link", entry != nil, attributes["rel"] == "alternate", let href = attributes["href"],
                   let url = URL(string: href), url.path.hasPrefix("/\(GitHubUpdateService.repository)/releases/tag/") { entry?.tag = url.lastPathComponent }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                switch name {
                case "title": entry?.title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case "updated": entry?.updated = text.trimmingCharacters(in: .whitespacesAndNewlines)
                case "content": entry?.notes = ReleaseFeed.plainText(html: text)
                case "entry": if let entry, !entry.tag.isEmpty { entries.append(entry) }; entry = nil
                default: break
                }
            }
        }
        let parser = XMLParser(data: data), reader = Reader(); parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? reader.entries : nil
    }
    /// Turns GitHub's rendered notes back into the Markdown subset the notes view shows.
    static func plainText(html: String) -> String {
        var text = html
        for (pattern, replacement) in [("<h[1-6][^>]*>", "\n## "), ("<li[^>]*>", "\n- "), ("<br\\s*/?>", "\n"), ("</(p|h[1-6]|li|ul|ol)>", "\n"), ("<[^>]+>", "")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
