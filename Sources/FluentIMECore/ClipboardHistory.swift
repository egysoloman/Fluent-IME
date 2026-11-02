import AppKit
import Carbon
import CryptoKit
import ImageIO

public struct ClipboardEntry: Codable, Identifiable, Equatable {
    public enum Kind: String, Codable { case text, richText, image, files, link }
    public let id: UUID
    public let items: [[String: Data]]
    public let date: Date
    public var isPinned: Bool
    public var kind: Kind {
        let types = Set(items.flatMap { $0.keys })
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return .files }
        if !types.isDisjoint(with: Self.imageTypes) { return .image }
        if types.contains(NSPasteboard.PasteboardType.rtf.rawValue) || types.contains(NSPasteboard.PasteboardType.html.rawValue) { return .richText }
        if types.contains(NSPasteboard.PasteboardType.URL.rawValue) { return .link }
        return .text
    }
    public var text: String {
        items.compactMap { item in
            for type in [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.URL.rawValue] {
                if let data = item[type], let text = String(data: data, encoding: .utf8) { return text }
            }
            if let data = item[NSPasteboard.PasteboardType.fileURL.rawValue], let text = String(data: data, encoding: .utf8), let url = URL(string: text) { return url.lastPathComponent }
            return nil
        }.joined(separator: "\n")
    }
    public var byteCount: Int { items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }
    static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif"]
    static let allowedTypes = imageTypes.union(["public.utf8-plain-text", "public.rtf", "public.html", "public.file-url", "public.url"])
    var isValid: Bool {
        !items.isEmpty && items.count <= 20 && byteCount <= 20_000_000 && items.allSatisfy { !$0.isEmpty && $0.allSatisfy { Self.allowedTypes.contains($0.key) && $0.value.count <= 8_000_000 } }
    }
    public func thumbnail() -> NSImage? {
        for item in items {
            for type in Self.imageTypes.sorted() {
                guard let data = item[type], let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0, width <= 16384, height <= 16384,
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 420] as CFDictionary) else { continue }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return nil
    }
}

/// Non-pinned entries are memory-only. Pinning is the sole path to encrypted storage.
/// Main-thread access; test histories use private pasteboards and injected vaults.
public final class ClipboardHistory {
    public static let changed = Notification.Name("FluentIMEClipboardHistoryChanged")
    public static let shared: ClipboardHistory = {
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--render-") }) {
            return ClipboardHistory(pasteboard: NSPasteboard(name: .init("FluentIME-Render-" + UUID().uuidString)), automaticPolling: false)
        }
        return ClipboardHistory(storage: ClipboardVault(directory: FluentProduct.current.supportDirectory.appendingPathComponent("Private/Clipboard"), encrypted: UserDefaults.standard.object(forKey: "clipboardEncryption") as? Bool ?? true), asynchronousStorage: true,
            encryptionChanged: { UserDefaults.standard.set($0, forKey: "clipboardEncryption") })
    }()
    public private(set) var entries: [ClipboardEntry] = []
    public private(set) var isRecording = false
    public enum StorageActivity { case loading, saving, clearing }
    public private(set) var storageActivity: StorageActivity?
    public var isStorageBusy: Bool { storageActivity != nil }
    private let storageQueue = DispatchQueue(label: "org.fluentime.clipboard.storage", qos: .userInitiated)
    public private(set) var storageError: String?
    public private(set) var storageEncrypted = true
    private let encryptionChanged: (Bool) -> Void
    private let pasteboard: NSPasteboard
    private let now: () -> Date
    public private(set) var retention: TimeInterval
    private let sensitiveInput: () -> Bool
    private let storage: ClipboardStoring?
    private var loaded = false
    private var lastChange: Int
    private var timer: Timer?
    private let automaticPolling: Bool
    public init(pasteboard: NSPasteboard = .general, retention: TimeInterval = 1800,
                automaticPolling: Bool = true, now: @escaping () -> Date = Date.init,
                sensitiveInput: @escaping () -> Bool = { IsSecureEventInputEnabled() }, storage: ClipboardStoring? = nil, asynchronousStorage: Bool = false, encryptionChanged: @escaping (Bool) -> Void = { _ in }) {
        self.pasteboard = pasteboard; self.now = now; self.retention = retention
        self.automaticPolling = automaticPolling; lastChange = pasteboard.changeCount
        self.sensitiveInput = sensitiveInput; self.storage = storage; self.encryptionChanged = encryptionChanged
        storageEncrypted = (storage as? ClipboardEncryptionStoring)?.isEncrypted ?? true
        if asynchronousStorage, storage != nil { performStorage(.load) { _ in } }
        else { do { try loadPins() } catch { storageError = L10n.clipboardStorageError } }
    }
    private func loadPins() throws {
        guard !loaded else { return }
        let pins = try storage?.load() ?? []
        entries = pins + entries.filter { entry in !entry.isPinned && !pins.contains(where: { $0.items == entry.items }) }
        storageEncrypted = (storage as? ClipboardEncryptionStoring)?.isEncrypted ?? storageEncrypted
        trimUnpinned(); loaded = true; storageError = nil
    }
    public func setRetention(_ seconds: TimeInterval) { retention = max(0, seconds); expire(); maintainTimer(); notify() }
    private func maintainTimer() {
        let needed = isRecording || (retention > 0 && entries.contains { !$0.isPinned })
        if automaticPolling, timer == nil, needed {
            let next = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
            timer = next; RunLoop.main.add(next, forMode: .common)
        } else if !needed { timer?.invalidate(); timer = nil }
    }
    public func setRecording(_ value: Bool) {
        isRecording = value; lastChange = pasteboard.changeCount
        maintainTimer(); notify()
    }
    private func trimUnpinned() {
        while entries.count > 50 || entries.reduce(0, { $0 + $1.byteCount }) > 50_000_000 {
            guard let index = entries.lastIndex(where: { !$0.isPinned }) else { break }
            entries.remove(at: index)
        }
    }
    private func expire() {
        let count = entries.count
        if retention > 0 { entries.removeAll { !$0.isPinned && now().timeIntervalSince($0.date) >= retention } }
        if entries.count != count { notify() }
    }
    public func poll() {
        expire(); maintainTimer()
        guard isRecording else {
            if !entries.contains(where: { !$0.isPinned }) { timer?.invalidate(); timer = nil }
            return
        }
        let change = pasteboard.changeCount
        guard change != lastChange else { return }; lastChange = change
        guard !sensitiveInput() else { return }
        let rawItems = pasteboard.pasteboardItems ?? []
        guard !rawItems.isEmpty, rawItems.count <= 20 else { return }
        let types = Set(((pasteboard.types ?? []) + rawItems.flatMap(\.types)).map { $0.rawValue.lowercased() })
        guard !types.contains(where: { $0.contains("concealed") || $0.contains("transient") || $0.contains("password") || $0.contains("autogenerated") }),
              !types.contains("com.agilebits.onepassword"), !types.contains("com.apple.is-remote-clipboard") else { return }
        var items: [[String: Data]] = []
        for raw in rawItems {
            var values: [String: Data] = [:]
            for type in raw.types where ClipboardEntry.allowedTypes.contains(type.rawValue) {
                guard let data = raw.data(forType: type), data.count <= 8_000_000 else { return }
                if type == .string && data.count > 64_000 { return }
                if type == .fileURL {
                    guard let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.isFileURL else { return }
                }
                values[type.rawValue] = data
            }
            if !values.isEmpty { items.append(values) }
        }
        let entry = ClipboardEntry(id: UUID(), items: items, date: now(), isPinned: false)
        guard pasteboard.changeCount == change, entry.isValid,
              entry.kind != .text || !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if entries.contains(where: { $0.isPinned && $0.items == items }) { return }
        entries.removeAll { !$0.isPinned && $0.items == items }
        entries.insert(entry, at: 0)
        trimUnpinned()
        notify()
    }
    public func setPinned(_ id: UUID, _ pinned: Bool) throws {
        guard !isStorageBusy else { throw ClipboardError.busy }
        do {
            try storage?.authorize(); try loadPins()
            guard let index = entries.firstIndex(where: { $0.id == id }), let storage else { throw ClipboardError.storage }
            var updated = entries; updated[index].isPinned = pinned
            try storage.save(updated.filter(\.isPinned))
            entries = updated; storageError = nil; expire(); maintainTimer(); notify()
        } catch { storageError = error.localizedDescription; notify(); throw error }
    }
    public func remove(_ id: UUID) throws {
        guard !isStorageBusy else { throw ClipboardError.busy }
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if entry.isPinned {
            try storage?.authorize(); try loadPins()
            try storage?.save(entries.filter { $0.id != id && $0.isPinned })
        }
        entries.removeAll { $0.id == id }; maintainTimer(); notify()
    }
    public func clear() throws {
        guard !isStorageBusy else { throw ClipboardError.busy }
        try storage?.erase()
        entries.removeAll(); loaded = true; storageError = nil; lastChange = pasteboard.changeCount
        if !isRecording { timer?.invalidate(); timer = nil }
        notify()
    }
    private enum StorageOperation { case load, pin(ClipboardEntry, Bool), remove(UUID), clear, encryption(Bool) }

    /// UI mutations keep authorization, encryption and disk I/O off the IMK thread.
    public func setPinned(_ id: UUID, _ pinned: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let entry = entries.first(where: { $0.id == id }) else { completion(.failure(ClipboardError.invalid)); return }
        performStorage(.pin(entry, pinned), completion: completion)
    }
    public func remove(_ id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isStorageBusy else { completion(.failure(ClipboardError.busy)); return }
        guard let entry = entries.first(where: { $0.id == id }) else { completion(.success(())); return }
        if !entry.isPinned {
            entries.removeAll { $0.id == id }; maintainTimer()
            DispatchQueue.main.async { [weak self] in self?.notify(); completion(.success(())) }
        } else { performStorage(.remove(id), completion: completion) }
    }
    public func clear(completion: @escaping (Result<Void, Error>) -> Void) {
        performStorage(.clear, completion: completion)
    }
    public func setEncryption(_ enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        performStorage(.encryption(enabled), completion: completion)
    }
    private func performStorage(_ operation: StorageOperation, completion: @escaping (Result<Void, Error>) -> Void) {
        precondition(Thread.isMainThread)
        guard !isStorageBusy else { completion(.failure(ClipboardError.busy)); return }
        switch operation {
        case .load: storageActivity = .loading
        case .clear: storageActivity = .clearing
        default: storageActivity = .saving
        }
        // Defer notification until the menu/button action has finished unwinding.
        DispatchQueue.main.async { [weak self] in self?.notify() }
        let storage = self.storage
        storageQueue.async { [self] in
            let result = Result<[ClipboardEntry], Error> {
                if case .clear = operation { try storage?.erase(); return [] }
                guard let storage else { throw ClipboardError.storage }
                if case .encryption(let enabled) = operation {
                    guard let configurable = storage as? ClipboardEncryptionStoring else { throw ClipboardError.storage }
                    try configurable.setEncryption(enabled)
                    return try storage.load()
                }
                if case .load = operation {} else { try storage.authorize() }
                var pins = try storage.load()
                switch operation {
                case .load: return pins
                case .pin(var entry, let pinned):
                    pins.removeAll { $0.id == entry.id || $0.items == entry.items }
                    if pinned { entry.isPinned = true; pins.append(entry) }
                case .remove(let id): pins.removeAll { $0.id == id }
                case .clear, .encryption: break
                }
                try storage.save(pins)
                return pins
            }
            let encrypted = (storage as? ClipboardEncryptionStoring)?.isEncrypted
            DispatchQueue.main.async { [self] in
                storageActivity = nil
                switch result {
                case .success(let pins):
                    if let encrypted { storageEncrypted = encrypted; encryptionChanged(encrypted) }
                    var temporary = entries.filter { !$0.isPinned }
                    switch operation {
                    case .clear: temporary = []; lastChange = pasteboard.changeCount
                    case .remove(let id): temporary.removeAll { $0.id == id }
                    case .pin(var entry, false):
                        entry.isPinned = false
                        if !temporary.contains(where: { $0.id == entry.id }) { temporary.append(entry) }
                    default: break
                    }
                    // Clipboard polling can add new entries while storage is busy.
                    entries = pins + temporary.filter { entry in !pins.contains(where: { $0.items == entry.items }) }
                    loaded = true; storageError = nil; trimUnpinned(); expire(); maintainTimer(); notify()
                    completion(.success(()))
                case .failure(let error):
                    storageError = error.localizedDescription; notify(); completion(.failure(error))
                }
            }
        }
    }
    public func copy(_ entry: ClipboardEntry, to destination: NSPasteboard = .general) -> Bool {
        let objects = entry.items.map { values -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for (type, data) in values { object.setData(data, forType: .init(type)) }
            return object
        }
        destination.clearContents()
        let success = destination.writeObjects(objects)
        if destination.name == pasteboard.name { lastChange = destination.changeCount }
        return success
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
    deinit { timer?.invalidate() }
}
