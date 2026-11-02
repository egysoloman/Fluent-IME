import Foundation
import CRimeBridge

public struct Candidate: Equatable {
    public let text: String
    public let comment: String
    public init(_ text: String, comment: String = "") { self.text = text; self.comment = comment }
}

public struct Composition: Equatable {
    public var preedit = ""
    public var rawInput = ""
    /// Rime's converted text for the whole composition (selected and pending segments).
    public var commitPreview = ""
    public var cursorUTF16 = 0
    public var candidates: [Candidate] = []
    public var highlighted = 0
    public var page = 0
    public var pageSize = 7
    public var candidateIndices: [Int] = []
    public var isContinuous = false
    public var hasMoreCandidates = false
    public var isLastPage = true
    public var isComposing: Bool { !rawInput.isEmpty }
    public init() {}
}

public enum EngineError: LocalizedError {
    case missingData(String), sessionUnavailable
    public var errorDescription: String? {
        switch self {
        case .missingData(let path): return L10n.errorMissingData(path)
        case .sessionUnavailable: return L10n.errorSessionUnavailable
        }
    }
}

/// Own one engine per process. Call on the main thread; sessions keep it alive.
public final class RimeEngine {
    public let sharedDirectory: URL
    public let userDirectory: URL
    public var grammarAvailable: Bool { FIMHasGrammar() }
    public var version: String { String(cString: FIMVersion()) }

    public init(sharedDirectory: URL, userDirectory: URL, fullCheck: Bool = false) throws {
        guard ["fluent_pinyin", "fluent_bopomofo"].contains(where: { FileManager.default.fileExists(atPath: sharedDirectory.appendingPathComponent($0 + ".schema.yaml").path) }) else {
            throw EngineError.missingData(sharedDirectory.path)
        }
        self.sharedDirectory = sharedDirectory
        self.userDirectory = userDirectory
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        FIMInitialize(sharedDirectory.path, userDirectory.path, fullCheck, version)
        repairDamagedUserDictionaries()
        removeOutdatedCaches(keeping: "build-" + version)
    }

    /// LevelDB stops accepting writes once it meets a corrupted block, so learning would
    /// silently stop. Rebuild such a dictionary from what can still be read; the damaged
    /// database and the export are kept in DictionaryBackups next to the Rime folder.
    private func repairDamagedUserDictionaries() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil) else { return }
        for database in items where database.pathExtension == "userdb" {
            let logs = ["LOG", "LOG.old"].compactMap { try? String(contentsOf: database.appendingPathComponent($0), encoding: .utf8) }
            guard logs.contains(where: { $0.contains("Corruption:") }) else { continue }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = userDirectory.deletingLastPathComponent().appendingPathComponent("DictionaryBackups/\(stamp)-repair")
            guard (try? fm.createDirectory(at: backup, withIntermediateDirectories: true)) != nil else { continue }
            let entries = FIMRebuildUserDict(database.deletingPathExtension().lastPathComponent, backup.path)
            NSLog("Fluent IME: rebuilt damaged %@ (%d entries kept)", database.lastPathComponent, entries)
        }
    }
    /// Compiled user data is isolated per release; earlier releases' copies are only caches.
    private func removeOutdatedCaches(keeping current: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil) else { return }
        for cache in items where cache.lastPathComponent.hasPrefix("build-") && cache.lastPathComponent != current { try? fm.removeItem(at: cache) }
    }

    public func makeSession() throws -> RimeSession { try RimeSession(engine: self) }
    deinit { FIMFinalize() }
}

public final class RimeSession {
    private let engine: RimeEngine
    private let id: FIMSession

    fileprivate init(engine: RimeEngine) throws {
        self.engine = engine
        id = FIMCreateSession()
        guard id != 0 else { throw EngineError.sessionUnavailable }
        setOption("ascii_mode", false)
    }
    deinit { FIMDestroySession(id) }

    @discardableResult public func process(key: Int32, modifiers: Int32 = 0) -> Bool { FIMProcessKey(id, key, modifiers) }
    @discardableResult public func select(_ index: Int) -> Bool { FIMSelectCandidate(id, Int32(clamping: index)) }
    @discardableResult public func selectAbsolute(_ index: Int) -> Bool { FIMSelectAbsoluteCandidate(id, Int32(clamping: index)) }
    @discardableResult public func highlightAbsolute(_ index: Int) -> Bool { FIMHighlightAbsoluteCandidate(id, Int32(clamping: index)) }
    public var caretPosition: Int {
        get { Int(FIMGetCaretPosition(id)) }
        set { FIMSetCaretPosition(id, Int32(clamping: max(0, min(newValue, composition.rawInput.utf8.count)))) }
    }
    public func candidates(from start: Int, limit: Int = 64) -> (items: [Candidate], hasMore: Bool) {
        guard let pointer = FIMReadCandidates(id, Int32(clamping: start), Int32(clamping: min(256, max(1, limit)))) else { return ([], false) }
        defer { FIMFreeCandidates(pointer) }
        let batch = pointer.pointee
        return ((0..<Int(batch.count)).map { Candidate(String(cString: batch.texts[$0]!), comment: String(cString: batch.comments[$0]!)) }, batch.has_more)
    }
    public func setOption(_ option: String, _ value: Bool) { FIMSetOption(id, option, value) }
    @discardableResult public func selectSchema(_ schema: String) -> Bool { FIMSelectSchema(id, schema) }
    public func clear() { FIMClear(id) }
    public func commit() { FIMCommit(id) }

    public func takeCommit() -> String? {
        guard let value = FIMTakeCommit(id) else { return nil }
        defer { FIMFreeString(value) }
        return String(cString: value)
    }

    public var composition: Composition {
        guard let pointer = FIMGetContext(id) else { return Composition() }
        defer { FIMFreeContext(pointer) }
        var context = pointer.pointee
        var result = Composition()
        result.preedit = String(cString: context.preedit)
        result.rawInput = String(cString: context.input)
        result.commitPreview = String(cString: context.commit_preview)
        // librime offsets are UTF-8 bytes; InputMethodKit expects UTF-16 units.
        result.cursorUTF16 = Self.utf16Offset(in: result.preedit, utf8Offset: Int(context.cursor_utf8))
        result.page = Int(context.page)
        result.pageSize = max(1, Int(context.page_size))
        result.candidateIndices = (0..<Int(context.count)).map { result.page * result.pageSize + $0 }
        result.isLastPage = context.last_page
        result.highlighted = Int(context.highlighted)
        withUnsafeBytes(of: &context.candidates) { texts in
            withUnsafeBytes(of: &context.comments) { comments in
                let textPointers = texts.bindMemory(to: UnsafeMutablePointer<CChar>?.self)
                let commentPointers = comments.bindMemory(to: UnsafeMutablePointer<CChar>?.self)
                for index in 0..<Int(context.count) {
                    result.candidates.append(Candidate(String(cString: textPointers[index]!), comment: String(cString: commentPointers[index]!)))
                }
            }
        }
        return result
    }

    public static func utf16Offset(in text: String, utf8Offset: Int) -> Int {
        let bytes = Array(text.utf8.prefix(max(0, utf8Offset)))
        // A malformed midpoint is clamped back to the previous complete scalar.
        for count in stride(from: bytes.count, through: 0, by: -1) {
            if let prefix = String(bytes: bytes.prefix(count), encoding: .utf8) { return prefix.utf16.count }
        }
        return 0
    }
}
