import AppKit
import FluentKit
import FluentIMECore

protocol IMEUpdateService {
    func latest() async throws -> GitHubRelease?
    func download(_ release: GitHubRelease, to directory: URL, progress: (@Sendable (UpdateDownloadProgress) -> Void)?) async throws -> URL
}
extension GitHubUpdateService: IMEUpdateService {}

@MainActor final class UpdateCoordinator {
    static let shared = UpdateCoordinator()
    static let changed = Notification.Name("FluentIMEUpdateStateChanged")
    enum State { case idle, checking, available(String), current, downloading(Int64, Int64), verifying, opening, opened, cancelled, failed(String) }
    private(set) var state: State = .idle { didSet { NotificationCenter.default.post(name: Self.changed, object: self) } }
    private var task: Task<Void, Never>?
    private var generation = 0
    private var release: GitHubRelease?
    private let service: any IMEUpdateService
    private var updateWindow: NSWindow?
    init(service: any IMEUpdateService = GitHubUpdateService()) { self.service = service }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var busy: Bool {
        switch state { case .checking, .downloading, .verifying, .opening: return true; default: return false }
    }
    var canInstall: Bool { release != nil && !busy }
    func check() {
        guard !busy else { return }
        generation += 1; let request = generation; release = nil; state = .checking
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await service.latest(); try Task.checkCancellation()
                guard request == generation else { return }
                if let latest, latest.isNewer(than: currentVersion) { release = latest; state = .available(latest.version) }
                else { state = latest == nil ? .failed(L10n.updateNoRelease) : .current }
            } catch { if request == generation, !Task.isCancelled { state = .failed(error.localizedDescription) } }
            if request == generation { task = nil }
        }
    }
    func cancel() {
        if case .opening = state { return }
        generation += 1; task?.cancel(); task = nil; state = .cancelled
    }
    func install() {
        guard let release, !busy else { return }
        generation += 1; let request = generation
        state = .downloading(0, release.installer(for: .current)?.size ?? 0)
        let previous = InstallerLifecycle.isInstaller ? [Bundle.main.bundleURL.path] + InstallerLifecycle.previousInstallers : []
        let waitForParent = InstallerLifecycle.isInstaller
        task = Task { [weak self] in
            guard let self else { return }
            let directory = InputMethodInstallation.shared.files.support.appendingPathComponent("Updates/" + UUID().uuidString)
            do {
                let file = try await service.download(release, to: directory) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == request, case .downloading = self.state else { return }
                        switch progress {
                        case .downloading(let received, let total): self.state = .downloading(received, total)
                        case .verifying: self.state = .verifying
                        }
                    }
                }
                try Task.checkCancellation(); guard request == generation else { throw CancellationError() }
                state = .opening
                let launcher = Task.detached { try UpdatedInstaller.launch(file, version: release.version, previous: previous, waitForParent: waitForParent) }
                try await withTaskCancellationHandler(operation: { try await launcher.value }, onCancel: { launcher.cancel() })
                guard request == generation else { return }
                self.release = nil; state = .opened
                if waitForParent { NSApp.terminate(nil) }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if request == generation, !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
            if request == generation { task = nil }
        }
    }
    // The installer uses the same update page in its own window.
    func present(in root: NSView) {
        if let updateWindow { updateWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.updatePageTitle; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false; window.styleMask.insert(.fullSizeContentView)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        let content = IMEFlippedView(); content.wantsLayer = true; content.layer?.backgroundColor = IMEThemeObservation.current.windowBackground.cgColor; window.contentView = content
        let title = FluentTitleBar(title: L10n.updatePageTitle, heightMode: .compact, backgroundStyle: .transparent, windowControlsStyle: .windows)
        let bar = title._makeView(in: FluentRenderContext(theme: IMEThemeObservation.current, locale: L10n.locale)); bar.frame = NSRect(x: 0, y: 0, width: 600, height: 40); content.addSubview(bar)
        let page = UpdatePageView(coordinator: self); page.frame = NSRect(x: 32, y: 72, width: 536, height: 280); content.addSubview(page)
        updateWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class UpdatePageView: NSView {
    private let coordinator: UpdateCoordinator
    private let version = NSTextField(labelWithString: "")
    private let status = FluentSelectableLabel(wrappingLabelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progress = FluentProgressBar(value: 0)
    private let primary = FluentButton(title: "", role: .primary)
    private let cancel = FluentButton(title: L10n.commonCancel)
    private var observer: NSObjectProtocol?
    private var themeObservation: IMEThemeObservation?
    override var isFlipped: Bool { true }
    convenience init() { self.init(coordinator: .shared) }
    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator; super.init(frame: .zero)
        for view in [version, status, detail, progress, primary, cancel] { addSubview(view) }
        primary.onClick = { [weak coordinator] in guard let coordinator else { return }; if coordinator.canInstall { coordinator.install() } else { coordinator.check() } }
        cancel.onClick = { [weak coordinator] in coordinator?.cancel() }
        observer = NotificationCenter.default.addObserver(forName: UpdateCoordinator.changed, object: coordinator, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        themeObservation = IMEThemeObservation { [weak self] _ in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refresh() {
        let theme = IMEThemeObservation.current
        version.stringValue = L10n.updateInstalledVersion(coordinator.currentVersion)
        version.font = IMEFont.font(ofSize: 20, weight: .medium); version.textColor = theme.textPrimary
        status.font = IMEFont.font(ofSize: 14); status.theme = theme; status.textColor = theme.textPrimary
        detail.font = IMEFont.font(ofSize: 12); detail.textColor = theme.textSecondary
        progress.theme = theme; primary.theme = theme; cancel.theme = theme
        progress.isHidden = !coordinator.busy
        if case .downloading(_, let total) = coordinator.state { progress.isIndeterminate = total <= 0 }
        else { progress.isIndeterminate = true }
        detail.stringValue = ""
        switch coordinator.state {
        case .idle: status.stringValue = L10n.updateIdle
        case .checking: status.stringValue = L10n.updateChecking
        case .available(let version): status.stringValue = L10n.updateAvailable(version)
        case .current: status.stringValue = L10n.updateCurrent(coordinator.currentVersion)
        case .downloading(let received, let total):
            status.stringValue = L10n.updateDownloading
            progress.value = total > 0 ? min(100, Double(received) / Double(total) * 100) : 0
            let format = ByteCountFormatter(); format.countStyle = .file
            detail.stringValue = "\(format.string(fromByteCount: received)) / \(format.string(fromByteCount: total))"
        case .verifying: status.stringValue = L10n.updateVerifying
        case .opening: status.stringValue = L10n.updateOpening
        case .opened: status.stringValue = L10n.updateOpened
        case .cancelled: status.stringValue = L10n.updateCancelled
        case .failed(let message): status.stringValue = message
        }
        primary.title = coordinator.canInstall ? L10n.updateInstall : L10n.updateTitle
        primary.isEnabled = !coordinator.busy; cancel.isHidden = !coordinator.busy
        if case .opening = coordinator.state { cancel.isEnabled = false } else { cancel.isEnabled = true }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        version.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 32)
        status.frame = NSRect(x: 0, y: 52, width: bounds.width, height: 76)
        progress.frame = NSRect(x: 0, y: 142, width: bounds.width, height: 8)
        detail.frame = NSRect(x: 0, y: 162, width: bounds.width, height: 24)
        let width = min(bounds.width * 0.65, max(220, primary.intrinsicContentSize.width))
        primary.frame = NSRect(x: 0, y: 216, width: width, height: 32)
        cancel.frame = NSRect(x: width + 12, y: 216, width: min(120, bounds.width - width - 12), height: 32)
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
private enum UpdatedInstaller {
    static func launch(_ file: URL, version: String, previous: [String], waitForParent: Bool) throws {
        func run(_ path: String, _ arguments: [String]) throws -> Data {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError.integrity }; return data
        }
        try Task.checkCancellation()
        _ = try run("/usr/bin/hdiutil", ["verify", "-quiet", file.path])
        let data = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-plist", file.path])
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let path = (info?["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first else { throw UpdateError.integrity }
        let mount = URL(fileURLWithPath: path); var launched = false
        defer { if !launched { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) } }
        let app = mount.appendingPathComponent("Fluent IME Setup.app")
        guard let metadata = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              metadata["CFBundleIdentifier"] as? String == InstallerLifecycle.identifier,
              metadata["CFBundleShortVersionString"] as? String == version else { throw UpdateError.integrity }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try Task.checkCancellation()
        let process = Process(); process.executableURL = app.appendingPathComponent("Contents/MacOS/FluentSetup")
        process.arguments = Array(previous.prefix(4)).flatMap { ["--previous-installer", $0] } + (waitForParent ? ["--relaunch-after", String(getpid())] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); launched = true
    }
}
