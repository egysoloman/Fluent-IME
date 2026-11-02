import AppKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

public struct GIFEntry: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
}

public enum GIFLibraryError: LocalizedError {
    case invalidFile, tooLarge, tooMany
    public var errorDescription: String? {
        switch self {
        case .invalidFile: return L10n.errorGifInvalid
        case .tooLarge: return L10n.errorGifTooLarge
        case .tooMany: return L10n.errorGifTooMany
        }
    }
}

/// Owns copies of explicitly selected files, never modifies the originals.
public final class GIFLibrary {
    public static let shared = GIFLibrary(directory: FluentProduct.current.supportDirectory.appendingPathComponent("GIFs"))
    public let directory: URL
    public private(set) var entries: [GIFEntry] = []
    public init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([GIFEntry].self, from: data) {
            entries = Array(saved.filter { $0.id.count == 64 && $0.id.allSatisfy { "0123456789abcdef".contains($0) } && FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.id + ".gif").path) }.prefix(100))
        }
    }
    public func url(for entry: GIFEntry) -> URL { directory.appendingPathComponent(entry.id + ".gif") }
    @discardableResult public func add(_ source: URL) throws -> GIFEntry {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw GIFLibraryError.invalidFile }
        guard (values.fileSize ?? Int.max) <= 20_000_000 else { throw GIFLibraryError.tooLarge }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count <= 20_000_000 else { throw GIFLibraryError.tooLarge }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(image) > 0 else { throw GIFLibraryError.invalidFile }
        guard CGImageSourceGetCount(image) <= 300 else { throw GIFLibraryError.tooLarge }
        for frame in 0..<CGImageSourceGetCount(image) {
            let props = CGImageSourceCopyPropertiesAtIndex(image, frame, nil) as? [CFString: Any]
            guard let width = props?[kCGImagePropertyPixelWidth] as? Int,
                  let height = props?[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 4096, height <= 4096 else { throw GIFLibraryError.tooLarge }
        }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = entries.first(where: { $0.id == id }) { return existing }
        guard entries.count < 100 else { throw GIFLibraryError.tooMany }
        let entry = GIFEntry(id: id, name: source.deletingPathExtension().lastPathComponent)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url(for: entry), options: .atomic)
        let updated = [entry] + entries
        try save(updated); entries = updated
        return entry
    }
    public func remove(_ entry: GIFEntry) throws {
        let updated = entries.filter { $0.id != entry.id }
        try save(updated); entries = updated
        // The source selected by the user is untouched; only our copy is removed.
        try FileManager.default.removeItem(at: url(for: entry))
    }
    public func copy(_ entry: GIFEntry, to pasteboard: NSPasteboard = .general) throws {
        let data = try Data(contentsOf: url(for: entry))
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.gif.identifier))
        item.setString(url(for: entry).absoluteString, forType: .fileURL)
        pasteboard.clearContents(); pasteboard.writeObjects([item])
    }
    private func save(_ updated: [GIFEntry]) throws {
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
    }
}
