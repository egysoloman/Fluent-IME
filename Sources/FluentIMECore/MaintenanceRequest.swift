import Foundation

/// Only product-specific operations cross the UI/maintenance boundary. Requests
/// never contain an install destination, a shell command, or a path to delete.
public enum MaintenanceRequest: Codable, Equatable {
    case show
    case uninstall(keepData: Bool)
    case update(file: URL, version: String)
    case finishSetup(installers: [URL])
}

public struct MaintenanceRequestStore {
    private struct Envelope: Codable {
        let created: Date
        let request: MaintenanceRequest
    }
    public let directory: URL
    public init(support: URL) { directory = support.resolvingSymlinksInPath().appendingPathComponent("MaintenanceRequests", isDirectory: true) }

    public func create(_ request: MaintenanceRequest, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try check(directory, type: .typeDirectory)
        let file = directory.appendingPathComponent(UUID().uuidString + ".json")
        let data = try JSONEncoder().encode(Envelope(created: now, request: request))
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// Consume once, before doing any work. Stale or malformed requests must not
    /// replay an earlier uninstall when the maintenance app is opened again.
    public func consume(_ file: URL, now: Date = Date()) throws -> MaintenanceRequest {
        guard file.isFileURL, file.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL,
              file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { throw CocoaError(.fileReadNoPermission) }
        try check(directory, type: .typeDirectory)
        try check(file, type: .typeRegular)
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
        guard let size, size.intValue <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard (-5...120).contains(now.timeIntervalSince(envelope.created)) else { throw CocoaError(.fileReadCorruptFile) }
        return envelope.request
    }

    private func check(_ url: URL, type: FileAttributeType) throws {
        // Check ancestors too; accepting a symlinked request directory could
        // otherwise turn the one-time consume into a delete outside our store.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CocoaError(.fileReadNoPermission) }
        let info = try FileManager.default.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == type,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = info[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw CocoaError(.fileReadNoPermission) }
    }
}

/// This receipt is written only after the download was checked against the
/// release manifest. Maintenance verifies the bytes again before mounting it.
public struct VerifiedUpdateReceipt: Codable {
    public let version: String
    public let edition: ReleaseEdition
    public let size: Int64
    public let sha256: String
    public static let filename = "verified-update.json"

    public init(version: String, edition: ReleaseEdition, size: Int64, sha256: String) {
        self.version = version; self.edition = edition; self.size = size; self.sha256 = sha256
    }
    public func save(beside file: URL) throws {
        let target = file.deletingLastPathComponent().appendingPathComponent(Self.filename)
        guard FileManager.default.createFile(atPath: target.path, contents: try JSONEncoder().encode(self), attributes: [.posixPermissions: 0o600]) else { throw UpdateError.integrity }
    }
    public static func validate(file: URL, version: String, updates: URL) throws -> Self {
        let folder = file.deletingLastPathComponent()
        guard file.isFileURL, ReleaseVersion(version) != nil,
              folder.deletingLastPathComponent().standardizedFileURL == updates.standardizedFileURL,
              UUID(uuidString: folder.lastPathComponent) != nil,
              file.standardizedFileURL.path == file.resolvingSymlinksInPath().path,
              (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw UpdateError.integrity }
        let receiptFile = folder.appendingPathComponent(filename)
        guard receiptFile.standardizedFileURL.path == receiptFile.resolvingSymlinksInPath().path,
              (try receiptFile.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max < 16_384 else { throw UpdateError.integrity }
        let receipt = try JSONDecoder().decode(Self.self, from: Data(contentsOf: receiptFile))
        let name = "Fluent-IME-\(version)\(receipt.edition == .full ? "-Full" : "")-Setup.dmg"
        guard receipt.version == version, file.lastPathComponent == name, (1...2_000_000_000).contains(receipt.size) else { throw UpdateError.integrity }
        try GitHubUpdateService.verify(file: file, expectedSize: receipt.size, sha256: receipt.sha256)
        return receipt
    }
}
