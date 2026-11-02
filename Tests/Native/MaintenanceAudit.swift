import AppKit
import FluentKit
import FluentIMECore

@main struct MaintenanceAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        final class Installation: MaintenanceInstallation {
            var isPresent = true
            var installedVersion: String? = "0.6.4"
            var hasInstallerPayload = true
            var choice: Bool?
            var completion: ((Result<Void, Error>) -> Void)?
            func remove(keepData: Bool, completion: @escaping (Result<Void, Error>) -> Void) { choice = keepData; self.completion = completion }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
        func capture(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for payload in [false, true] {
                let fixture = Installation(); fixture.hasInstallerPayload = payload
                let window = MaintenanceWindowController(installation: fixture)
                window.showWindow(nil); pump()
                let root = window.window!.contentView!
                let buttons = all(root).compactMap { $0 as? FluentButton }
                let actions = buttons.filter { [L10n.updateTitle, L10n.settingsTitle, L10n.maintenanceInstall, L10n.uninstallAction].contains($0.title) }
                precondition(actions.count == (payload ? 4 : 3))
                precondition(Set(actions.map { $0.frame.minX }).count == 1 && Set(actions.map { $0.frame.width }).count == 1)
                for label in all(root).compactMap({ $0 as? FluentSelectableLabel }) {
                    let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000))
                    precondition(needed.height <= label.bounds.height + 1 && root.bounds.contains(label.frame), "Maintenance text clipped")
                }
                let prefix = "\(dark ? "dark" : "light")-\(payload ? "installer" : "maintenance")"
                try capture(root, prefix)
                let uninstall = actions.first { $0.title == L10n.uninstallAction }!
                precondition(uninstall.role == .primary)
                uninstall.onClick?(); pump()
                let check = all(root).compactMap { $0 as? FluentCheckBox }.first!
                precondition(check.isChecked)
                check.isChecked = payload; check.onValueChanged?(payload)
                let confirm = all(root).compactMap { $0 as? FluentButton }.first { $0.identifier?.rawValue == "FluentKit.ContentDialog.primary" }!
                precondition(confirm.role == .primary)
                try capture(root, prefix + "-uninstall")
                confirm.onClick?(); pump()
                precondition(fixture.choice == payload, "Uninstall did not carry the keep-data choice")
                precondition(window.busy && !window.canTerminate)
                precondition(all(root).compactMap { $0 as? FluentProgressBar }.contains { $0.isIndeterminate })
                try capture(root, prefix + "-removing")
                fixture.isPresent = false; fixture.installedVersion = nil; fixture.completion?(.success(())); pump()
                precondition(!window.busy && window.canTerminate)
                let expected = payload ? L10n.maintenanceRemovedKeepingData : L10n.maintenanceRemoved
                precondition(all(root).compactMap { $0 as? FluentSelectableLabel }.contains { $0.stringValue == expected })
                try capture(root, prefix + "-removed")
                window.window?.orderOut(nil)
            }
        }
        let failed = Installation()
        let failingWindow = MaintenanceWindowController(installation: failed)
        failingWindow.handle(.uninstall(keepData: true)); failed.completion?(.failure(CocoaError(.fileWriteNoPermission)))
        precondition(!failingWindow.busy && failed.isPresent)
        // A call in the input-method process must not execute maintenance directly.
        var rejected = false
        InputMethodInstallation.shared.remove(keepData: false) { if case .failure = $0 { rejected = true } }
        precondition(rejected)
        InputMethodInstallation.shared.install { result in if case .success = result { preconditionFailure("Input method executed installer directly") } }
        print("Maintenance UI passed: \(L10n.locale.identifier), both themes, install/uninstall entries, keep/remove choice, progress, failure and process boundary")
    }
}
