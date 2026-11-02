import AppKit
import FluentIMECore

enum InstallerLifecycle {
    static let identifier = "org.fluentime.installer"
    static var isInstaller: Bool { Bundle.main.bundleIdentifier == identifier }
    static var isMaintenance: Bool { isInstaller || Bundle.main.bundleIdentifier == "org.fluentime.maintenance" }
    static var previousInstallers: [String] {
        let args = CommandLine.arguments
        return Array(args.indices.compactMap { i in args[i] == "--previous-installer" && i + 1 < args.count ? args[i + 1] : nil }.prefix(4))
    }
    static var payload: URL {
        if isInstaller { return Bundle.main.resourceURL!.appendingPathComponent("Payload/Fluent IME.app") }
        let enclosingApp = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if (NSDictionary(contentsOf: enclosingApp.appendingPathComponent("Contents/Info.plist")))?["CFBundleIdentifier"] as? String == "org.fluentime.inputmethod.FluentIME" { return enclosingApp }
        return InstallationFiles().application
    }
    static func preparePreferences() {
        // Wizard controls are drafts. Read existing preferences without writing them.
        UserDefaults.standard.addSuite(named: "org.fluentime.inputmethod.FluentIME")
    }
    static func removeTemporaryMaintenanceCopy() {
        guard Bundle.main.bundleIdentifier == "org.fluentime.maintenance" else { return }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let prefix = "FluentIME-Maintenance-"
        guard parent.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath(),
              parent.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(parent.lastPathComponent.dropFirst(prefix.count))) != nil else { return }
        try? FileManager.default.removeItem(at: parent)
    }
    static func commitPreferences() {
        let shared = UserDefaults(suiteName: "org.fluentime.inputmethod.FluentIME")!
        for key in ["enabledInputModes", "defaultInputMode", "clipboardRetention", "clipboardRecording", "advancedEffects", "showInputModeIndicator", "setupCompleted"] {
            if let value = UserDefaults.standard.object(forKey: key) { shared.set(value, forKey: key) }
        }
        shared.synchronize()
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? identifier)
    }
    static func finishCleanup(installer: URL) throws {
        let readOnly = try installer.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly ?? true
        var disks: [String: Any] = [:]
        if readOnly {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["info", "-plist"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if process.terminationStatus == 0 { disks = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:] }
        }
        let target = try InstallerCleanup.target(installer: installer, readOnly: readOnly, diskImages: disks)
        if let volume = target.mountedVolume {
            // The installer has exited; no executable remains on this mounted image.
            // Never force-detach a busy volume. Keep the installer if detaching fails.
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["detach", volume.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try FileManager.default.trashItem(at: target.item, resultingItemURL: nil)
    }
}
