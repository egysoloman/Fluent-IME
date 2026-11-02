import AppKit
import Carbon
import FluentKit
import FluentIMECore

@main struct SetupLayoutAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // A Mac without the input method registered gets NULL from TIS; setup must not crash on it.
        precondition(InputMethodInstallation.inputSources([kTISPropertyBundleID as String: "org.fluentime.audit.unregistered"]).isEmpty)
        _ = InputMethodInstallation.shared.isEnabled
        final class Installation: SetupInstallation {
            var isInstalled = false, isEnabled = false, hasLocalDictionary = true
            var newerInstalledVersion: String?
            func install(completion: @escaping (Result<Void, Error>) -> Void) { isInstalled = true; completion(.success(())) }
            func enable() throws { isEnabled = true }
            func complete(resetDictionary: Bool, applyPreferences: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) { fatalError("Layout audit must not commit preferences") }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let controller = SetupWindowController(installation: Installation())
            controller.showWindow(nil)
            let root = controller.window!.contentView!
            for step in 0..<5 {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
                root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
                if step == 0 { precondition(!all(root).contains { ($0 as? FluentButton)?.title == L10n.updateTitle }, "The guide has no update entry") }
                for label in all(root).compactMap({ $0 as? FluentSelectableLabel }) where !label.stringValue.isEmpty {
                    let needed = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000))
                    if needed.height > label.bounds.height + 1 { fputs("Clipped text: \(label.stringValue), needed=\(needed.height), actual=\(label.bounds.height)\n", stderr) }
                    precondition(needed.height <= label.bounds.height + 1, "Clipped text: \(label.stringValue), needed=\(needed.height), actual=\(label.bounds.height)")
                    precondition(label.superview!.bounds.contains(label.frame), "Label extends outside its page")
                }
                let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(dark ? "dark" : "light")-step-\(step + 1).png"))
                if step < 4 {
                    let title = step == 0 ? L10n.installAction : step == 1 ? L10n.installEnable : L10n.setupNext
                    all(root).compactMap { $0 as? FluentButton }.first { $0.title == title }!.onClick?()
                }
            }
            controller.window?.orderOut(nil)
        }
        // Without a local dictionary there is nothing to keep or reset, so that step is skipped.
        let fresh = Installation(); fresh.hasLocalDictionary = false; fresh.isInstalled = true; fresh.isEnabled = true
        let short = SetupWindowController(installation: fresh); short.showWindow(nil)
        let shortRoot = short.window!.contentView!
        var shortTitles: [String] = []
        for _ in 0..<4 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.65))
            let texts = all(shortRoot).compactMap { ($0 as? NSTextField)?.stringValue }
            precondition(texts.contains { $0 == L10n.setupStep(shortTitles.count + 1, 4) }, "Step count must drop to 4")
            shortTitles.append(texts.first { [L10n.installWelcome, L10n.installEnable, L10n.settingsDictionaryTitle, L10n.setupModes, L10n.setupPrivacy].contains($0) } ?? "")
            all(shortRoot).compactMap { $0 as? FluentButton }.first { $0.title == L10n.setupNext }?.onClick?()
        }
        precondition(shortTitles == [L10n.installWelcome, L10n.installEnable, L10n.setupModes, L10n.setupPrivacy], "Dictionary step must be skipped: \(shortTitles)")
        short.window?.orderOut(nil)
        // Opening the installer checks for a newer one before looking at the local installation.
        final class Updates: IMEUpdateService {
            var results: [Result<GitHubRelease?, Error>], calls = 0, delay: UInt64 = 0
            init(_ results: [Result<GitHubRelease?, Error>]) { self.results = results }
            func latest(channel: UpdateChannel) async throws -> GitHubRelease? {
                calls += 1; if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                return try results.removeFirst().get()
            }
            func history(channel: UpdateChannel) async throws -> [GitHubRelease] { [] }
            func download(_ release: GitHubRelease, to directory: URL, progress: (@Sendable (UpdateDownloadProgress) -> Void)?) async throws -> URL { throw UpdateError.integrity }
        }
        func texts(_ root: NSView) -> [String] { all(root).compactMap { ($0 as? NSTextField)?.stringValue } }
        func button(_ title: String, _ root: NSView) -> FluentButton? { all(root).compactMap { $0 as? FluentButton }.first { $0.title == title } }
        func capture(_ root: NSView, _ name: String) throws {
            root.layoutSubtreeIfNeeded(); root.displayIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!; root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        let newer = GitHubRelease(tag_name: "v99.0.0", draft: false, prerelease: false, assets: [])
        let slow = Updates([.success(newer)]); slow.delay = 1_500_000_000
        let outdated = SetupWindowController(installation: Installation(), updates: slow); outdated.showWindow(nil)
        var root = outdated.window!.contentView!
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
        precondition(texts(root).contains(L10n.updateChecking) && button(L10n.installAction, root)?.isEnabled == false, "Checking comes first and blocks installing")
        precondition(!texts(root).contains(L10n.installNotInstalled), "The local installation is checked only after the update check")
        try capture(root, "check-running")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.6))
        precondition(texts(root).contains { $0.contains("99.0.0") } && button(L10n.setupDownloadLatest, root) != nil, "A newer release must be offered")
        try capture(root, "check-outdated")
        button(L10n.setupContinue, root)!.onClick?(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        precondition(button(L10n.setupDownloadLatest, root) == nil && button(L10n.installAction, root)?.isEnabled == true && texts(root).contains(L10n.installNotInstalled))
        outdated.window?.orderOut(nil)
        let offline = Updates([.failure(URLError(.notConnectedToInternet)), .success(nil)])
        let retrying = SetupWindowController(installation: Installation(), updates: offline); retrying.showWindow(nil)
        root = retrying.window!.contentView!; RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        precondition(texts(root).contains(L10n.setupOffline) && button(L10n.setupRetry, root) != nil, "Offline must offer retry or continue")
        try capture(root, "check-offline")
        button(L10n.setupRetry, root)!.onClick?(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        precondition(offline.calls == 2 && button(L10n.setupRetry, root) == nil && button(L10n.installAction, root)?.isEnabled == true)
        retrying.window?.orderOut(nil)
        let installed = Installation(); installed.isInstalled = true; installed.newerInstalledVersion = "9.9.9"
        let current = SetupWindowController(installation: installed, updates: Updates([.success(nil)])); current.showWindow(nil)
        root = current.window!.contentView!; RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        precondition(texts(root).contains(L10n.installNewerInstalled("9.9.9")) && button(L10n.setupContinue, root) == nil, "A newer local install is reported without a dialog")
        try capture(root, "check-newer-installed")
        current.window?.orderOut(nil)
        print("Setup layout passed: \(L10n.locale.identifier), 5 steps, light + dark, no text clipping, update check before local check")
    }
}
