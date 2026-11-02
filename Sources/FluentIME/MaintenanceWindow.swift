import AppKit
import FluentKit
import FluentIMECore

/// The maintenance program's windowless modes. Update and uninstall run without UI
/// and end by relaunching the input method or quitting; only a failure is reported.
/// Every other launch opens the setup guide instead.
final class MaintenanceTasks {
    private let installation: any MaintenanceInstallation
    private let report: (Error) -> Void
    private let finish: () -> Void
    private(set) var busy = false
    var canTerminate: Bool { !busy }

    init(installation: any MaintenanceInstallation = InputMethodInstallation.shared,
         report: @escaping (Error) -> Void = MaintenanceTasks.alert,
         finish: @escaping () -> Void = { NSApp.terminate(nil) }) {
        self.installation = installation; self.report = report; self.finish = finish
    }
    static func alert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = L10n.maintenanceTitle; alert.informativeText = error.localizedDescription
        alert.runModal()
    }
    func fail(_ error: Error) { busy = false; report(error); finish() }

    func handle(_ request: MaintenanceRequest) {
        guard !busy else { return }
        busy = true
        switch request {
        case .show: busy = false
        case .uninstall(let keep):
            installation.remove(keepData: keep) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.busy = false; self.finish()
                case .failure(let error): self.fail(error)
                }
            }
        case .update(let file, let version):
            Task { @MainActor in
                do {
                    try await Task.detached { try MaintenanceUpdateExecutor.launch(file, version: version, previous: [], waitForParent: true) }.value
                    busy = false; finish()
                } catch { fail(error) }
            }
        case .finishSetup(let installers):
            Task { @MainActor in
                do {
                    try await Task.detached {
                        guard installers.count <= 5 else { throw CocoaError(.fileReadCorruptFile) }
                        for url in Set(installers) where FileManager.default.fileExists(atPath: url.path) {
                            try InstallerLifecycle.finishCleanup(installer: url)
                        }
                    }.value
                    busy = false; finish()
                } catch { fail(NSError(domain: "FluentIME.Setup", code: 3, userInfo: [NSLocalizedDescriptionKey: L10n.installCleanupWarning])) }
            }
        }
    }
    /// Installs this installer's payload over an older version, then reopens the input method.
    func applyBundledUpdate() {
        guard installation.hasInstallerPayload else { fail(UpdateError.integrity); return }
        busy = true
        let enabled = InputMethodInstallation.shared.isEnabled
        InputMethodInstallation.shared.install { [weak self] result in
            guard let self else { return }
            do {
                try result.get()
                if enabled { try InputMethodInstallation.shared.enable(); InputMethodInstallation.shared.restoreSelection() }
                self.busy = false
                try InputMethodInstallation.shared.relaunchAndQuit()
            } catch { self.fail(error) }
        }
    }
}

final class MaintenanceAppDelegate: NSObject, NSApplicationDelegate {
    var tasks: MaintenanceTasks?
    var setup: SetupWindowController?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { tasks?.canTerminate == false ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { InstallerLifecycle.removeTemporaryMaintenanceCopy() }
    func showSetup() {
        if setup == nil { setup = SetupWindowController() }
        setup?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
