import Foundation
import CryptoKit
import Security

public enum ClipboardError: LocalizedError {
    case storage, limit, invalid
    public var errorDescription: String? {
        switch self {
        case .storage: return L10n.clipboardStorageError
        case .limit: return L10n.clipboardLimitError
        case .invalid: return L10n.clipboardInvalidError
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

/// Only ciphertext reaches disk. The key is a non-synchronizing login-keychain item;
/// never fall back to a key file or replace an inaccessible/corrupt existing vault.
public final class ClipboardVault: ClipboardStoring {
    public let directory: URL
    private let key: (Bool) throws -> SymmetricKey
    private let usesKeychain: Bool
    private var file: URL { directory.appendingPathComponent("pinned.aesgcm") }
    private let authenticatedHeader = Data("FluentIME.Clipboard.v1".utf8)
    public init(directory: URL, key: ((Bool) throws -> SymmetricKey)? = nil) {
        self.directory = directory; usesKeychain = key == nil
        self.key = key ?? { try ClipboardVault.keychainKey(create: $0) }
    }
    /// Called only for a deliberate pin/unpin action, never by the clipboard poller.
    public func authorize() throws {
        if usesKeychain { _ = try Self.keychainKey(create: !FileManager.default.fileExists(atPath: file.path), allowInteraction: true) }
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
        let encrypted = try Data(contentsOf: file)
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key(false), authenticating: authenticatedHeader)
        let saved = try JSONDecoder().decode([ClipboardEntry].self, from: data)
        guard saved.count <= 50, saved.allSatisfy({ $0.isPinned && $0.isValid }), saved.reduce(0, { $0 + $1.byteCount }) <= 50_000_000 else { throw ClipboardError.invalid }
        return saved
    }
    public func save(_ entries: [ClipboardEntry]) throws {
        guard entries.count <= 50, entries.allSatisfy({ $0.isPinned && $0.isValid }), entries.reduce(0, { $0 + $1.byteCount }) <= 50_000_000 else { throw ClipboardError.limit }
        if entries.isEmpty { try erase(); return }
        try checkDirectory(create: true)
        let plaintext = try JSONEncoder().encode(entries)
        let encrypted = try AES.GCM.seal(plaintext, using: key(true), authenticating: authenticatedHeader).combined!
        try encrypted.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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
