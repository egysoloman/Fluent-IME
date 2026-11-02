import AppKit
import FluentKit
import FluentIMECore

final class MaintenanceWindowController: NSWindowController, NSWindowDelegate {
    private let root = IMEFlippedView()
    private let installation: any MaintenanceInstallation
    private let showSetup: () -> Void
    private var themeObservation: IMEThemeObservation?
    private var status = ""
    private(set) var busy = false
    private var finished = false
    var canTerminate: Bool { !busy }

    init(installation: any MaintenanceInstallation = InputMethodInstallation.shared, showSetup: @escaping () -> Void = {}) {
        self.installation = installation; self.showSetup = showSetup
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: installation.hasInstallerPayload ? 492 : 440), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L10n.maintenanceTitle; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView); window.isReleasedWhenClosed = false
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(type)?.isHidden = true }
        super.init(window: window)
        window.contentView = root; window.delegate = self; root.wantsLayer = true
        themeObservation = IMEThemeObservation { [weak self] _ in self?.build() }
        build(); window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        if !CommandLine.arguments.contains("--render-audit") { NSApp.terminate(nil) }
    }
    private func build() {
        let theme = IMEThemeObservation.current
        root.subviews.forEach { $0.removeFromSuperview() }; root.layer?.backgroundColor = theme.windowBackground.cgColor
        let titlebar = FluentTitleBar(title: L10n.maintenanceTitle, heightMode: .compact, backgroundStyle: .transparent, windowControlsStyle: .windows)
        let bar = titlebar._makeView(in: FluentRenderContext(theme: theme, locale: L10n.locale)); bar.frame = NSRect(x: 0, y: 0, width: 600, height: 40); root.addSubview(bar)
        func label(_ text: String, y: CGFloat, height: CGFloat, size: CGFloat = 14, secondary: Bool = false) {
            let label = FluentSelectableLabel(wrappingLabelWithString: text); label.theme = theme
            label.font = IMEFont.font(ofSize: size); label.textColor = secondary ? theme.textSecondary : theme.textPrimary
            label.frame = NSRect(x: 40, y: y, width: 520, height: height); root.addSubview(label)
        }
        func button(_ title: String, x: CGFloat = 40, y: CGFloat, width: CGFloat = 250, role: FluentButtonRole = .standard, enabled: Bool = true, action: @escaping () -> Void) {
            let button = FluentButton(title: title, role: role); button.theme = theme; button.isEnabled = enabled && !busy
            button.frame = NSRect(x: x, y: y, width: width, height: 36); button.onClick = action; root.addSubview(button)
        }
        label(L10n.maintenanceTitle, y: 76, height: 42, size: 26)
        var version = installation.installedVersion.map(L10n.updateInstalledVersion) ?? L10n.installNotInstalled
        if let payload = installation.payloadVersion, payload != installation.installedVersion { version += " · " + L10n.maintenancePayloadVersion(payload) }
        label(version, y: 130, height: 32, secondary: true)
        label(status.isEmpty ? L10n.maintenanceDetail : status, y: 176, height: 72, secondary: status.isEmpty)
        if busy {
            let progress = FluentProgressBar(value: 0); progress.theme = theme; progress.isIndeterminate = true
            progress.frame = NSRect(x: 40, y: 272, width: 520, height: 8); root.addSubview(progress)
        } else if finished {
            button(L10n.commonClose, x: 310, y: 352, role: .primary) { [weak self] in self?.close() }
        } else {
            button(L10n.updateTitle, y: 260, width: 520, role: .primary) { [weak self] in Task { @MainActor in if let root = self?.root { UpdateCoordinator.shared.present(in: root) } } }
            button(L10n.uninstallAction, y: installation.hasInstallerPayload ? 410 : 360, width: 520, role: .primary, enabled: installation.isPresent) { [weak self] in
                guard let self else { return }
                MaintenanceDialogs.uninstall(in: self.root, accepted: { [weak self] keep in self?.requestUninstall(keepData: keep) })
            }
            if installation.hasInstallerPayload {
                button(L10n.maintenanceInstall, y: 360, width: 520) { [weak self] in self?.showSetup() }
            }
            button(L10n.settingsTitle, y: 310, width: 520, enabled: installation.isPresent) {
                do { try InputMethodInstallation.shared.launchInstalled() }
                catch { MaintenanceDialogs.showError(error, in: self.root) }
            }
        }
    }

    func handle(_ request: MaintenanceRequest) {
        guard !busy else { return }
        switch request {
        case .show: break
        case .uninstall(let keep): remove(keepData: keep)
        case .update(let file, let version):
            busy = true; status = L10n.maintenanceVerifying; build()
            Task { @MainActor in
                do {
                    try await Task.detached { try MaintenanceUpdateExecutor.launch(file, version: version, previous: [], waitForParent: true) }.value
                    busy = false; NSApp.terminate(nil)
                } catch { busy = false; status = error.localizedDescription; build() }
            }
        case .finishSetup(let installers):
            busy = true
            Task { @MainActor in
                do {
                    try await Task.detached {
                        guard installers.count <= 5 else { throw CocoaError(.fileReadCorruptFile) }
                        for url in Set(installers) where FileManager.default.fileExists(atPath: url.path) {
                            try InstallerLifecycle.finishCleanup(installer: url)
                        }
                    }.value
                    busy = false; NSApp.terminate(nil)
                } catch {
                    busy = false
                    showFailure(NSError(domain: "FluentIME.Setup", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.installCleanupWarning]))
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
    private func requestUninstall(keepData: Bool) {
        // An embedded maintenance app first stages a copy outside the app that
        // will be removed. A separately downloaded installer can run directly.
        if Bundle.main.bundleURL.path.hasPrefix(InputMethodInstallation.shared.files.application.path + "/") {
            busy = true; status = L10n.maintenanceOpening; build()
            Task { @MainActor in
                do { try await MaintenanceClient.launch(.uninstall(keepData: keepData)); busy = false; close() }
                catch { busy = false; status = error.localizedDescription; build() }
            }
        } else { remove(keepData: keepData) }
    }
    private func remove(keepData: Bool) {
        busy = true; status = L10n.maintenanceRemoving; build()
        installation.remove(keepData: keepData) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success: self.finished = true; self.status = keepData ? L10n.maintenanceRemovedKeepingData : L10n.maintenanceRemoved
            case .failure(let error): self.status = error.localizedDescription
            }
            self.build()
        }
    }
    func showFailure(_ error: Error) { status = error.localizedDescription; build(); showWindow(nil) }

    func applyBundledUpdate() {
        guard installation.hasInstallerPayload else { showFailure(UpdateError.integrity); return }
        busy = true; status = L10n.installBusy; build()
        let enabled = InputMethodInstallation.shared.isEnabled
        InputMethodInstallation.shared.install { [weak self] result in
            guard let self else { return }
            do {
                try result.get()
                if enabled { try InputMethodInstallation.shared.enable() }
                self.busy = false
                try InputMethodInstallation.shared.relaunchAndQuit()
            } catch { self.busy = false; self.status = error.localizedDescription; self.build() }
        }
    }
}

final class MaintenanceAppDelegate: NSObject, NSApplicationDelegate {
    var controller: MaintenanceWindowController?
    var setup: SetupWindowController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { controller?.canTerminate == false ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { InstallerLifecycle.removeTemporaryMaintenanceCopy() }
    func showSetup() {
        if setup == nil { setup = SetupWindowController() }
        setup?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
