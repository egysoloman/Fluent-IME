import Foundation

/// File operations are separated from TIS and UI so lifecycle transactions can be tested
/// entirely in a temporary home directory without changing the user's installation.
public struct InstallationFiles {
    public let home: URL
    public let product: FluentProduct
    public var application: URL { home.appendingPathComponent("Library/Input Methods/" + product.appFileName) }
    public var support: URL { product.support(in: home) }
    public var dictionary: URL { support.appendingPathComponent("Rime") }
    public var isInstalled: Bool {
        guard let info = NSDictionary(contentsOf: application.appendingPathComponent("Contents/Info.plist")) else { return false }
        return info["CFBundleIdentifier"] as? String == product.bundleID
            && FileManager.default.isExecutableFile(atPath: application.appendingPathComponent("Contents/MacOS/FluentIME").path)
    }
    public var hasLocalDictionary: Bool {
        guard let files = FileManager.default.enumerator(at: dictionary, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in files where file.lastPathComponent.hasSuffix(".userdb") || file.lastPathComponent == "custom_phrase.txt" { return true }
        return false
    }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, product: FluentProduct = .current) {
        self.home = home.standardizedFileURL; self.product = product
    }
    private func backupDirectory(_ kind: String) throws -> URL {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let target = support.appendingPathComponent(kind).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return target
    }
    public func install(from source: URL) throws {
        let fm = FileManager.default
        if source.resolvingSymlinksInPath() == application.resolvingSymlinksInPath() { return }
        guard let info = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == product.bundleID,
              fm.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/FluentIME").path) else { throw CocoaError(.fileReadCorruptFile) }
        let staging = support.appendingPathComponent("InstallStaging/" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(product.appFileName)
        try fm.copyItem(at: source, to: staged)
        try fm.createDirectory(at: application.deletingLastPathComponent(), withIntermediateDirectories: true)
        var previous: URL?
        if fm.fileExists(atPath: application.path) {
            previous = try backupDirectory("Backups").appendingPathComponent(product.appFileName)
            try fm.moveItem(at: application, to: previous!)
        }
        do { try fm.moveItem(at: staged, to: application) }
        catch { if let previous { try? fm.moveItem(at: previous, to: application) }; throw error }
        if let previous { pruneApplicationBackups(keeping: previous.deletingLastPathComponent()) }
    }
    /// Each update moves the replaced app aside. Keep only the newest copy for recovery.
    func pruneApplicationBackups(keeping newest: URL) {
        let fm = FileManager.default, backups = support.appendingPathComponent("Backups")
        guard let folders = try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil) else { return }
        for folder in folders where folder.standardizedFileURL != newest.standardizedFileURL {
            // Only remove folders this installer created: one app copy and nothing else.
            guard (try? fm.contentsOfDirectory(atPath: folder.path)) == [product.appFileName] else { continue }
            try? fm.removeItem(at: folder)
        }
    }
    @discardableResult public func backupDictionary() throws -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dictionary.path) else { return nil }
        let backup = try backupDirectory("DictionaryBackups").appendingPathComponent("Rime")
        try fm.moveItem(at: dictionary, to: backup)
        do { try fm.createDirectory(at: dictionary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { try? fm.moveItem(at: backup, to: dictionary); throw error }
        return backup
    }
    /// Caller must first stop Rime and disable the input source. Only this input method is removed.
    public func uninstall(keepData: Bool, removeApplication: (URL) throws -> Void) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: application.path) { try removeApplication(application) }
        if !keepData, fm.fileExists(atPath: support.path) { try fm.removeItem(at: support) }
    }
}
