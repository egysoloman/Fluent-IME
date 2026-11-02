import AppKit
import Carbon
import FluentIMECore
import CRimeBridge

protocol SetupInstallation: AnyObject {
    var isInstalled: Bool { get }
    var isEnabled: Bool { get }
    var hasLocalDictionary: Bool { get }
    func install(completion: @escaping (Result<Void, Error>) -> Void)
    func enable() throws
    func complete(resetDictionary: Bool, applyPreferences: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void)
}
protocol MaintenanceInstallation: AnyObject {
    var hasInstallerPayload: Bool { get }
    func remove(keepData: Bool, completion: @escaping (Result<Void, Error>) -> Void)
}
final class InputMethodInstallation: SetupInstallation, MaintenanceInstallation {
    static let shared = InputMethodInstallation()
    let files = InstallationFiles()
    var isPresent: Bool { files.isInstalled }
    var installedVersion: String? { (NSDictionary(contentsOf: files.application.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String }
    var hasInstallerPayload: Bool { InstallerLifecycle.isMaintenance && FileManager.default.fileExists(atPath: InstallerLifecycle.payload.appendingPathComponent("Contents/MacOS/FluentIME").path) }
    private(set) var needsQuitAfterFailure = false
    var isInstalled: Bool {
        guard files.isInstalled else { return false }
        guard InstallerLifecycle.isMaintenance, hasInstallerPayload else { return true }
        let targetInfo = NSDictionary(contentsOf: files.application.appendingPathComponent("Contents/Info.plist"))
        let payloadInfo = NSDictionary(contentsOf: InstallerLifecycle.payload.appendingPathComponent("Contents/Info.plist"))
        guard (targetInfo?["FluentIMEEdition"] as? String ?? "full") == (payloadInfo?["FluentIMEEdition"] as? String ?? "full") else { return false }
        let target = targetInfo?["CFBundleVersion"] as? String ?? "0"
        let payload = payloadInfo?["CFBundleVersion"] as? String ?? "999999"
        return (Int(target) ?? 0) >= (Int(payload) ?? 999999)
    }
    var isEnabled: Bool { Self.sources().contains { Self.bool($0, kTISPropertyInputSourceIsEnabled) } }
    var hasLocalDictionary: Bool { files.hasLocalDictionary }
    var isRunningInstalled: Bool { Bundle.main.bundleURL.resolvingSymlinksInPath() == files.application.resolvingSymlinksInPath() }
    static func sources() -> [TISInputSource] {
        inputSources([kTISPropertyBundleID as String: "org.fluentime.inputmethod.FluentIME"])
    }
    /// TISCreateInputSourceList returns NULL rather than an empty list when nothing
    /// matches, as on a Mac where the input method has never been registered.
    static func inputSources(_ properties: [String: String], includeAllInstalled: Bool = true) -> [TISInputSource] {
        (TISCreateInputSourceList(properties as CFDictionary, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }
    private static func bool(_ source: TISInputSource, _ property: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(source, property) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
    private static func identifier(_ source: TISInputSource) -> String? {
        TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }
    private var selectionBeforeInstall: String?
    /// Installing selects ABC while the bundle is replaced; an update returns to the mode the user was typing in.
    func restoreSelection() {
        guard let id = selectionBeforeInstall, let source = Self.sources().first(where: { Self.identifier($0) == id }) else { return }
        _ = TISSelectInputSource(source)
    }
    static func check(_ status: OSStatus) throws { if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) } }
    func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard InstallerLifecycle.isMaintenance else { completion(.failure(CocoaError(.fileWriteNoPermission))); return }
        let source = InstallerLifecycle.payload
        selectionBeforeInstall = Self.sources().first { Self.bool($0, kTISPropertyInputSourceIsSelected) }.flatMap(Self.identifier)
        do { try selectFallbackIfNeeded() } catch { completion(.failure(error)); return }
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: "org.fluentime.inputmethod.FluentIME").filter {
            $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == files.application.standardizedFileURL
        }
        other.forEach { $0.terminate() }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result<Void, Error> {
                let deadline = Date(timeIntervalSinceNow: 8)
                while other.contains(where: { kill($0.processIdentifier, 0) == 0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                guard !other.contains(where: { kill($0.processIdentifier, 0) == 0 }) else { throw CocoaError(.fileWriteFileExists) }
                let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                verify.arguments = ["--verify", "--deep", "--strict", source.path]; verify.standardError = FileHandle.nullDevice
                try verify.run(); verify.waitUntilExit()
                guard verify.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
                try files.install(from: source)
                try Self.check(TISRegisterInputSource(files.application as CFURL))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func enable() throws {
        try Self.check(TISRegisterInputSource(files.application as CFURL))
        let sources = Self.sources()
        guard !sources.isEmpty else { throw NSError(domain: "FluentIME.Installation", code: 1, userInfo: [NSLocalizedDescriptionKey: L10n.registrationReloginHint]) }
        for source in sources { try Self.check(TISEnableInputSource(source)) }
    }
    func complete(resetDictionary: Bool, applyPreferences: @escaping () -> Void, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            guard isInstalled && isEnabled else { throw NSError(domain: "FluentIME.Installation", code: 2, userInfo: [NSLocalizedDescriptionKey: L10n.installRequired]) }
            if resetDictionary {
                try selectFallbackIfNeeded()
                if isRunningInstalled { FIMFinalize(); needsQuitAfterFailure = true }
                else { try stopInstalledProcesses() }
                try files.backupDictionary()
            }
            applyPreferences()
            if InstallerLifecycle.isMaintenance { InstallerLifecycle.commitPreferences() }
            if resetDictionary || !isRunningInstalled { try relaunchAndQuit() }
            else { completion(.success(())) }
        } catch { completion(.failure(error)) }
    }
    func launchInstalled(waitForParent: Bool = false) throws {
        let process = Process(); process.executableURL = files.application.appendingPathComponent("Contents/MacOS/FluentIME")
        process.arguments = ["--preview"] + (waitForParent ? ["--relaunch-after", String(getpid())] : [])
        if InstallerLifecycle.isInstaller && waitForParent { process.arguments = (process.arguments ?? []) + ["--finish-setup", Bundle.main.bundleURL.path] + InstallerLifecycle.previousInstallers.flatMap { ["--previous-installer", $0] } }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func relaunchAndQuit() throws { try launchInstalled(waitForParent: true); NSApp.terminate(nil) }
    func resetDictionaryAndRestart() throws {
        try selectFallbackIfNeeded(); FIMFinalize(); needsQuitAfterFailure = true
        try files.backupDictionary(); try relaunchAndQuit()
    }
    private func stopInstalledProcesses() throws {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "org.fluentime.inputmethod.FluentIME").filter { $0.processIdentifier != getpid() && $0.bundleURL?.standardizedFileURL == files.application.standardizedFileURL }
        others.forEach { $0.terminate() }
        let deadline = Date(timeIntervalSinceNow: 8)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
        guard others.allSatisfy({ $0.isTerminated }) else { throw CocoaError(.fileWriteFileExists) }
    }
    private func selectFallbackIfNeeded() throws {
        if Self.sources().contains(where: { Self.bool($0, kTISPropertyInputSourceIsSelected) }) {
            let fallback = Self.inputSources([kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"])
            guard let source = fallback.first else { throw CocoaError(.featureUnsupported) }
            try Self.check(TISEnableInputSource(source)); try Self.check(TISSelectInputSource(source))
        }
    }
    func remove(keepData: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard InstallerLifecycle.isMaintenance else { completion(.failure(CocoaError(.fileWriteNoPermission))); return }
        do {
            try selectFallbackIfNeeded()
            for source in Self.sources() { try Self.check(TISDisableInputSource(source)) }
        } catch { completion(.failure(error)); return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "org.fluentime.inputmethod.FluentIME").filter {
            $0.bundleURL?.standardizedFileURL == files.application.standardizedFileURL
        }
        others.forEach { $0.terminate() }
        DispatchQueue.global(qos: .userInitiated).async { [files] in
            let result = Result<Void, Error> {
                let deadline = Date(timeIntervalSinceNow: 8)
                while others.contains(where: { kill($0.processIdentifier, 0) == 0 }), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                guard !others.contains(where: { kill($0.processIdentifier, 0) == 0 }) else { throw CocoaError(.fileWriteFileExists) }
                try files.uninstall(keepData: keepData) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
                if !keepData {
                    UserDefaults.standard.removePersistentDomain(forName: "org.fluentime.inputmethod.FluentIME")
                    UserDefaults.standard.synchronize()
                    // Delete last: a failed application removal must never leave
                    // retained encrypted records without their key.
                    try ClipboardVault.deleteKeychainKey()
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
