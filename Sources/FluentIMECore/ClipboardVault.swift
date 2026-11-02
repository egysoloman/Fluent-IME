import Foundation
import CryptoKit
import Security

public enum ClipboardError: LocalizedError {
    case storage, limit, invalid, busy
    public var errorDescription: String? {
        switch self {
        case .storage: return L10n.clipboardStorageError
        case .limit: return L10n.clipboardLimitError
        case .invalid: return L10n.clipboardInvalidError
        case .busy: return L10n.clipboardSaving
        }
    }
}

public protocol ClipboardStoring {
    func load() throws -> [ClipboardEntry]
    func save(_ entries: [ClipboardEntry]) throws
    func erase() throws
    func authorize() throws
}
public extension ClipboardStoring { func authorize() throws {} }

public protocol ClipboardEncryptionStoring: ClipboardStoring {
    var isEncrypted: Bool { get }
    func setEncryption(_ enabled: Bool) throws
}

/// Encryption is optional. Both formats use an owner-only directory and file.
/// A tagged plaintext format shares the legacy filename so migration is one atomic
/// replacement; failed authorization never replaces existing encrypted data.
public final class ClipboardVault: ClipboardEncryptionStoring {
    public let directory: URL
    private let key: (Bool) throws -> SymmetricKey
    private let usesKeychain: Bool
    public private(set) var isEncrypted: Bool
    private var cachedKey: SymmetricKey?
    private let plainHeader = Data("FluentIME.Clipboard.plain.v1\n".utf8)
    private var file: URL { directory.appendingPathComponent("pinned.aesgcm") }
    private let authenticatedHeader = Data("FluentIME.Clipboard.v1".utf8)
    public init(directory: URL, encrypted: Bool = true, key: ((Bool) throws -> SymmetricKey)? = nil) {
        self.directory = directory; usesKeychain = key == nil; isEncrypted = encrypted
        self.key = key ?? { try ClipboardVault.keychainKey(create: $0) }
    }
    /// Called only for a deliberate pin/unpin action, never by the clipboard poller.
    public func authorize() throws {
        guard try storedEncryption() else { return }
        if usesKeychain, cachedKey == nil {
            cachedKey = try Self.keychainKey(create: !FileManager.default.fileExists(atPath: file.path), allowInteraction: true)
        }
    }
    private func storedEncryption() throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return isEncrypted }
        let stream = try FileHandle(forReadingFrom: file); defer { try? stream.close() }
        return try stream.read(upToCount: plainHeader.count) != plainHeader
    }
    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let resolved = try key(create); cachedKey = resolved; return resolved
    }
    public func setEncryption(_ enabled: Bool) throws {
        if FileManager.default.fileExists(atPath: file.path), try storedEncryption() { try authorize() }
        let entries = try load(), previous = isEncrypted
        guard previous != enabled else { return }
        if enabled, !entries.isEmpty, usesKeychain, cachedKey == nil {
            cachedKey = try Self.keychainKey(create: true, allowInteraction: true)
        }
        isEncrypted = enabled
        do { try save(entries) }
        catch { isEncrypted = previous; throw error }
        if !enabled { cachedKey = nil }
    }
    private func checkDirectory(create: Bool) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path), create {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        if fm.fileExists(atPath: directory.path) {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw ClipboardError.storage }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
    public func load() throws -> [ClipboardEntry] {
        try checkDirectory(create: false)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 75_000_000 else { throw ClipboardError.invalid }
        let stored = try Data(contentsOf: file)
        let encrypted = !stored.starts(with: plainHeader)
        let data = encrypted
            ? try AES.GCM.open(AES.GCM.SealedBox(combined: stored), using: encryptionKey(create: false), authenticating: authenticatedHeader)
            : Data(stored.dropFirst(plainHeader.count))
        let saved = try JSONDecoder().decode([ClipboardEntry].self, from: data)
        guard saved.count <= 50, saved.allSatisfy({ $0.isPinned && $0.isValid }), saved.reduce(0, { $0 + $1.byteCount }) <= 50_000_000 else { throw ClipboardError.invalid }
        isEncrypted = encrypted
        return saved
    }
    public func save(_ entries: [ClipboardEntry]) throws {
        guard entries.count <= 50, entries.allSatisfy({ $0.isPinned && $0.isValid }), entries.reduce(0, { $0 + $1.byteCount }) <= 50_000_000 else { throw ClipboardError.limit }
        if entries.isEmpty { try erase(); return }
        try checkDirectory(create: true)
        let plaintext = try JSONEncoder().encode(entries)
        let payload = isEncrypted
            ? try AES.GCM.seal(plaintext, using: encryptionKey(create: true), authenticating: authenticatedHeader).combined!
            : plainHeader + plaintext
        // Set permissions before the atomic rename, including the temporary file.
        let temporary = directory.appendingPathComponent(".clipboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClipboardError.storage }
        let stream = try FileHandle(forWritingTo: temporary)
        do { try stream.write(contentsOf: payload); try stream.synchronize(); try stream.close() }
        catch { try? stream.close(); throw error }
        guard rename(temporary.path, file.path) == 0 else { throw ClipboardError.storage }
        var target = file; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
    public func erase() throws {
        try checkDirectory(create: false)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public static func deleteKeychainKey() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.fluentime.clipboard.v1", kSecAttrAccount as String: "encryption-key",
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClipboardError.storage }
    }
    public static func keychainKey(create: Bool, service: String = "org.fluentime.clipboard.v1", allowInteraction: Bool = false) throws -> SymmetricKey {
        // This native IMK app is not App Sandbox signed. Use its own login-keychain
        // item instead of claiming Data Protection Keychain / Secure Enclave access.
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "encryption-key",
            kSecAttrSynchronizable as String: false]
        var query = identity
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw ClipboardError.storage }
        let key = SymmetricKey(size: .bits256)
        var item = identity
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrLabel as String] = "Fluent IME Clipboard"
        item[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem { return try keychainKey(create: false, service: service, allowInteraction: allowInteraction) }
        guard added == errSecSuccess else { throw ClipboardError.storage }
        return key
    }
}
