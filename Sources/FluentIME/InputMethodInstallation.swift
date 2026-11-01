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
final class InputMethodInstallation: SetupInstallation {
    static let shared = InputMethodInstallation()
    let files = InstallationFiles()
    private(set) var needsQuitAfterFailure = false
    var isInstalled: Bool {
        guard files.isInstalled else { return false }
        guard InstallerLifecycle.isInstaller else { return true }
        let target = NSDictionary(contentsOf: files.application.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String ?? "0"
        let payload = NSDictionary(contentsOf: InstallerLifecycle.payload.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String ?? "999999"
        return (Int(target) ?? 0) >= (Int(payload) ?? 999999)
    }
    var isEnabled: Bool { Self.sources().contains { Self.bool($0, kTISPropertyInputSourceIsEnabled) } }
    var hasLocalDictionary: Bool { files.hasLocalDictionary }
    var isRunningInstalled: Bool { Bundle.main.bundleURL.resolvingSymlinksInPath() == files.application.resolvingSymlinksInPath() }
    static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: "org.fluentime.inputmethod.FluentIME"] as CFDictionary
        return TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
    }
    private static func bool(_ source: TISInputSource, _ property: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(source, property) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
    static func check(_ status: OSStatus) throws { if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) } }
    func install(completion: @escaping (Result<Void, Error>) -> Void) {
        let source = InstallerLifecycle.isInstaller ? InstallerLifecycle.payload : Bundle.main.bundleURL
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
            if InstallerLifecycle.isInstaller { InstallerLifecycle.commitPreferences() }
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
            let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"] as CFDictionary
            let fallback = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
            guard let source = fallback.first else { throw CocoaError(.featureUnsupported) }
            try Self.check(TISEnableInputSource(source)); try Self.check(TISSelectInputSource(source))
        }
    }
    func uninstall(keepData: Bool) throws {
        let sources = Self.sources()
        try selectFallbackIfNeeded()
        for source in sources { try Self.check(TISDisableInputSource(source)) }
        ClipboardHistory.shared.setRecording(false)
        FIMFinalize(); needsQuitAfterFailure = true
        if !keepData { try ClipboardHistory.shared.clear(); try ClipboardVault.deleteKeychainKey() }
        try files.uninstall(keepData: keepData) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        if !keepData { UserDefaults.standard.removePersistentDomain(forName: "org.fluentime.inputmethod.FluentIME"); UserDefaults.standard.synchronize() }
        NSApp.terminate(nil)
    }
}
