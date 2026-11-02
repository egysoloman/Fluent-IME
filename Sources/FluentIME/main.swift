import AppKit
import InputMethodKit
import Carbon
import Security
import CryptoKit
import CRimeBridge
import FluentIMECore

final class AppDelegate: NSObject, NSApplicationDelegate {
    let preview: Bool
    var cleanupInstallers: [URL] = []
    init(preview: Bool) {
        self.preview = preview
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showSettingsNotification), name: Notification.Name("org.fluentime.showSettings"), object: nil)
    }
    @objc private func showSettingsNotification() { Runtime.shared.showSettings() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if preview { Runtime.shared.showSettings() }
        if !cleanupInstallers.isEmpty {
            Task { @MainActor in
                do { try await MaintenanceClient.launch(.finishSetup(installers: cleanupInstallers)) }
                catch { Runtime.shared.showInstallationCleanupError(error) }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Do not terminate in the middle of persisting a pinned clipboard item.
        // Maintenance times out without deleting data if storage is still busy.
        Runtime.hasStarted && ClipboardHistory.shared.isStorageBusy ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if Runtime.hasStarted { ClipboardHistory.shared.setRecording(false) }
        UserDefaults.standard.synchronize()
        FIMFinalize()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Runtime.shared.showSettings(); return true
    }
}

let arguments = CommandLine.arguments
// Isolated end-to-end Keychain probe for signed local builds; never touches the production key.
if arguments.contains("--audit-clipboard-keychain") {
    let service = "org.fluentime.clipboard.audit." + UUID().uuidString
    defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
    do {
        let first = try ClipboardVault.keychainKey(create: true, service: service)
        let second = try ClipboardVault.keychainKey(create: false, service: service)
        let sample = Data("FluentIME keychain audit".utf8)
        let sealed = try AES.GCM.seal(sample, using: first)
        guard try AES.GCM.open(sealed, using: second) == sample else { throw ClipboardError.invalid }
        print("Keychain create/read + AES-GCM round trip: passed")
    } catch { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary); fputs("Keychain audit failed: \(error.localizedDescription)\n", stderr); exit(1) }
    // Explicit cleanup before exit (Swift exit does not run defer).
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    exit(0)
}
if arguments.contains("--diagnose") {
    let controllerExists = NSClassFromString("FluentInputController") != nil
    print("Controller registered: \(controllerExists)")
    let filter = [kTISPropertyBundleID as String: "org.fluentime.inputmethod.FluentIME"] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
    for source in sources {
        func property(_ key: CFString) -> String {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return "nil" }
            return String(describing: Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue())
        }
        print("\(property(kTISPropertyInputSourceID)) enabled=\(property(kTISPropertyInputSourceIsEnabled)) selected=\(property(kTISPropertyInputSourceIsSelected))")
    }
    print("Registered input sources: \(sources.count)")
    exit(0)
}
if arguments.count >= 4, arguments[1] == "--deploy" {
    do {
        let engine = try RimeEngine(sharedDirectory: URL(fileURLWithPath: arguments[2]), userDirectory: URL(fileURLWithPath: arguments[3]), fullCheck: true)
        let session = try engine.makeSession()
        for byte in "nihao".utf8 { session.process(key: Int32(byte)) }
        guard session.composition.candidates.contains(where: { $0.text == "你好" }) else { throw EngineError.sessionUnavailable }
        print("Rime \(engine.version): dictionary deployed; nihao → 你好 verified.")
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

if arguments.contains("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print("TISRegisterInputSource: \(status)")
    let filter = [kTISPropertyInputSourceID as String: "org.fluentime.inputmethod.FluentIME.Hans"] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
    for source in sources { print("TISEnableInputSource: \(TISEnableInputSource(source))") }
    if sources.isEmpty { print(L10n.registrationReloginHint) }
    exit(status == noErr ? 0 : 1)
}

// Only the registered input method owns Rime. The separate installer runs its wizard without creating an IMK server.
if let index = arguments.firstIndex(of: "--relaunch-after"), arguments.count > index + 1,
   let parent = Int32(arguments[index + 1]), parent > 1 {
    let deadline = Date(timeIntervalSinceNow: 12)
    while kill(parent, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if kill(parent, 0) == 0 { exit(1) }
}
let rendering = arguments.contains(where: { $0.hasPrefix("--render-") })
let installation = InputMethodInstallation.shared
if !rendering, InstallerLifecycle.isMaintenance {
    InstallerLifecycle.preparePreferences()
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    let delegate = MaintenanceAppDelegate(); app.delegate = delegate
    if let index = arguments.firstIndex(of: "--maintenance-request"), arguments.count == index + 2 {
        let controller = MaintenanceWindowController(showSetup: { delegate.showSetup() }); delegate.controller = controller
        do {
            let request = try MaintenanceRequestStore(support: installation.files.support).consume(URL(fileURLWithPath: arguments[index + 1]))
            if case .finishSetup = request { app.setActivationPolicy(.accessory) }
            else if request == .show, !installation.isPresent, installation.hasInstallerPayload { delegate.showSetup() }
            else { controller.showWindow(nil) }
            if request != .show || installation.isPresent || !installation.hasInstallerPayload { controller.handle(request) }
        }
        catch { controller.showFailure(error) }
    } else if arguments.contains("--apply-update") || installation.isPresent || !InstallerLifecycle.isInstaller {
        let controller = MaintenanceWindowController(showSetup: { delegate.showSetup() }); delegate.controller = controller
        controller.showWindow(nil)
        if arguments.contains("--apply-update") { controller.applyBundledUpdate() }
    } else { delegate.showSetup() }
    if app.activationPolicy() != .accessory { app.activate(ignoringOtherApps: true) }
    withExtendedLifetime(delegate) { app.run() }; exit(0)
}
var cleanupInstallers: [URL] = []
if installation.isRunningInstalled, let index = arguments.firstIndex(of: "--finish-setup"), arguments.count > index + 1 {
    cleanupInstallers = Set([arguments[index + 1]] + InstallerLifecycle.previousInstallers).map { URL(fileURLWithPath: $0) }
}
if !rendering, !installation.isRunningInstalled, Bundle.main.bundleURL.pathExtension == "app" {
    let bundledVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    let installedVersion = (NSDictionary(contentsOf: installation.files.application.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String) ?? "0"
    if installation.isInstalled, (Int(installedVersion) ?? 0) >= (Int(bundledVersion) ?? 0) {
        do { try installation.launchInstalled(); exit(0) } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    let app = NSApplication.shared; app.setActivationPolicy(.regular)
    Task { @MainActor in
        do { try await MaintenanceClient.launch(.show); NSApp.terminate(nil) }
        catch { Runtime.shared.showError(error); NSApp.terminate(nil) }
    }
    app.run(); exit(0)
}
if arguments.contains("--preview"),
   NSRunningApplication.runningApplications(withBundleIdentifier: "org.fluentime.inputmethod.FluentIME").contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.standardizedFileURL == installation.files.application.standardizedFileURL }) {
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("org.fluentime.showSettings"), object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let preview = arguments.contains("--preview") || arguments.contains("--render-preview") || arguments.contains("--render-components")
app.setActivationPolicy(preview ? .regular : .accessory)
let delegate = AppDelegate(preview: preview)
delegate.cleanupInstallers = cleanupInstallers
app.delegate = delegate
let menu = NSMenu()
let item = NSMenuItem(); menu.addItem(item)
let appMenu = NSMenu(); item.submenu = appMenu
appMenu.addItem(withTitle: L10n.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let editItem = NSMenuItem(title: L10n.menuEdit, action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: L10n.menuEdit)
editItem.submenu = editMenu; menu.addItem(editItem)
editMenu.addItem(withTitle: L10n.menuUndo, action: Selector(("undo:")), keyEquivalent: "z")
let redo = editMenu.addItem(withTitle: L10n.menuRedo, action: Selector(("redo:")), keyEquivalent: "z")
redo.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(.separator())
editMenu.addItem(withTitle: L10n.menuCut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: L10n.menuCopy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: L10n.menuPaste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: L10n.menuSelectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
app.mainMenu = menu

if let index = arguments.firstIndex(of: "--render-components"), arguments.count > index + 1 {
    do { try renderReferenceComponents(to: URL(fileURLWithPath: arguments[index + 1]), engine: Runtime.shared.engine.get()) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

if let index = arguments.firstIndex(of: "--render-preview"), arguments.count > index + 1 {
    do {
        let controller = try SettingsWindowController(engine: Runtime.shared.engine.get())
        try controller.render(to: URL(fileURLWithPath: arguments[index + 1]))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

// Retain the server for the whole application lifetime; IMK instantiates controllers by ObjC name.
var inputServer: IMKServer?
// Settings and system input share one process. Opening settings must not prevent IMK connections.
inputServer = IMKServer(name: "FluentIME_Connection", bundleIdentifier: Bundle.main.bundleIdentifier ?? "org.fluentime.inputmethod.FluentIME")
app.run()
