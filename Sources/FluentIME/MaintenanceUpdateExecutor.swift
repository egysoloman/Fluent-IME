import AppKit
import FluentIMECore

enum MaintenanceUpdateExecutor {
    static func launch(_ file: URL, version: String, previous: [String], waitForParent: Bool) throws {
        func run(_ path: String, _ arguments: [String]) throws -> Data {
            let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw UpdateError.integrity }; return data
        }
        guard InstallerLifecycle.isMaintenance else { throw CocoaError(.fileWriteNoPermission) }
        _ = try VerifiedUpdateReceipt.validate(file: file, version: version, updates: InputMethodInstallation.shared.files.support.appendingPathComponent("Updates"))
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
        process.arguments = ["--apply-update"] + Array(previous.prefix(4)).flatMap { ["--previous-installer", $0] } + (waitForParent ? ["--relaunch-after", String(getpid())] : [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); launched = true
    }
}
