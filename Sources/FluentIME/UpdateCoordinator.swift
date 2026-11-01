import AppKit
import FluentKit
import FluentIMECore

@MainActor final class UpdateCoordinator {
    static let shared = UpdateCoordinator()
    private weak var root: NSView?
    private var host: NSView?
    private var task: Task<Void, Never>?
    private let service = GitHubUpdateService()
    func present(in root: NSView) {
        guard host == nil else { return }
        self.root = root; show(L10n.updateChecking, pending: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await service.latest(); try Task.checkCancellation()
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                if let release, release.isNewer(than: current) { show(L10n.updateAvailable(release.version)) { [weak self] in self?.download(release) } }
                else { show(release == nil ? L10n.updateNoRelease : L10n.updateCurrent(current)) }
            } catch { if !Task.isCancelled { show(error.localizedDescription) } }
        }
    }
    private func show(_ message: String, pending: Bool = false, action: (() -> Void)? = nil) {
        guard let root else { return }; host?.removeFromSuperview()
        var visible = true
        let label = FluentSelectableLabel(wrappingLabelWithString: message)
        label.font = IMEFont.font(ofSize: 14); label.textColor = IMEThemeObservation.current.textPrimary
        let dialog = FluentContentDialog(isPresented: FluentBinding(get: { visible }, set: { visible = $0 }),
            configuration: .init(title: L10n.updateTitle, primaryButtonText: pending ? nil : (action == nil ? L10n.commonClose : L10n.updateInstall), closeButtonText: pending || action != nil ? L10n.commonCancel : nil, defaultButton: pending ? .close : .primary),
            onClosed: { [weak self] result in
                guard let self else { return }; self.host?.removeFromSuperview(); self.host = nil
                if result == .primary, let action { action() } else { self.task?.cancel() }
            }, content: { FluentEmptyView() }, dialogContent: { FluentNativeView(label).frame(width: 380, height: 100) })
        let view = dialog._makeView(in: FluentRenderContext(theme: Preferences.shared.theme, locale: L10n.locale))
        view.frame = root.bounds; view.autoresizingMask = [.width, .height]; root.addSubview(view); host = view
    }
    private func download(_ release: GitHubRelease) {
        show(L10n.updateDownloading, pending: true)
        let previous = InstallerLifecycle.isInstaller ? [Bundle.main.bundleURL.path] + InstallerLifecycle.previousInstallers : []
        let waitForParent = InstallerLifecycle.isInstaller
        task = Task { [weak self] in
            guard let self else { return }
            let directory = InputMethodInstallation.shared.files.support.appendingPathComponent("Updates/" + UUID().uuidString)
            do {
                let file = try await service.download(release, to: directory); try Task.checkCancellation()
                let launcher = Task.detached { try UpdatedInstaller.launch(file, version: release.version, previous: previous, waitForParent: waitForParent) }
                try await withTaskCancellationHandler(operation: { try await launcher.value }, onCancel: { launcher.cancel() })
                host?.removeFromSuperview(); host = nil
                if waitForParent { NSApp.terminate(nil) }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if !Task.isCancelled { show(error.localizedDescription) }
            }
        }
    }
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
