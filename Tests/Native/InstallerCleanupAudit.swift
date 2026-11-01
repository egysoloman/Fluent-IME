import AppKit
import FluentIMECore

@main struct InstallerCleanupAudit {
    static func main() throws {
        let fm = FileManager.default, identifier = "FluentIME-Cleanup-Audit-" + UUID().uuidString
        let directory = fm.temporaryDirectory.appendingPathComponent(identifier)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        func fake(_ name: String) throws -> URL {
            let app = directory.appendingPathComponent(name + ".app")
            try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": InstallerLifecycle.identifier], format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
        func run(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let writable = try fake(identifier)
        try InstallerLifecycle.finishCleanup(installer: writable)
        precondition(!fm.fileExists(atPath: writable.path))
        let trashedApp = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/" + writable.lastPathComponent)
        precondition(fm.fileExists(atPath: trashedApp.path)); try fm.removeItem(at: trashedApp)
        let payload = try fake("Fluent IME Setup")
        let disk = directory.appendingPathComponent(identifier + ".dmg")
        let volume = URL(fileURLWithPath: "/Volumes/" + identifier)
        defer { if fm.fileExists(atPath: volume.path) { try? run(["detach", volume.path]) } }
        let mountedInstaller = volume.appendingPathComponent("Fluent IME Setup.app")
        let stage = directory.appendingPathComponent("image"); try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.moveItem(at: payload, to: stage.appendingPathComponent(payload.lastPathComponent))
        try run(["create", "-quiet", "-srcfolder", stage.path, "-volname", identifier, "-format", "UDZO", disk.path])
        try run(["attach", "-readonly", "-nobrowse", "-mountpoint", volume.path, disk.path])
        try InstallerLifecycle.finishCleanup(installer: mountedInstaller)
        precondition(!fm.fileExists(atPath: volume.path) && !fm.fileExists(atPath: disk.path))
        let trashedDisk = fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/" + disk.lastPathComponent)
        precondition(fm.fileExists(atPath: trashedDisk.path)); try fm.removeItem(at: trashedDisk)
        print("Writable installer → Trash; read-only DMG → eject → Trash: passed. Fixtures removed.")
    }
}
