import AppKit
import Security
import FluentIMECore

/// The settings UI downloads and confirms actions; a separate application owns
/// installation and removal. Launch Services gives that app its own lifecycle.
@MainActor enum MaintenanceClient {
    nonisolated static let identifier = FluentProduct.current.maintenanceID
    nonisolated static let relativePath = "Contents/Library/" + FluentProduct.current.maintenanceName + ".app"

    static func launch(_ request: MaintenanceRequest) async throws {
        let files = InputMethodInstallation.shared.files
        let source = Bundle.main.bundleURL.appendingPathComponent(relativePath)
        let embedded = FileManager.default.fileExists(atPath: source.path) ? source : files.application.appendingPathComponent(relativePath)
        let prepared = try await Task.detached { () throws -> (URL, URL?) in
            try verify(embedded)
            if case .uninstall = request {
                // Removal must not delete the executable/resources the maintenance
                // window is still using. This temporary copy contains no user data.
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-Maintenance-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let copy = directory.appendingPathComponent(embedded.lastPathComponent)
                do { try FileManager.default.copyItem(at: embedded, to: copy); try verify(copy) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                return (copy, directory)
            }
            return (embedded, nil)
        }.value
        let store = MaintenanceRequestStore(support: files.support)
        var pending: URL?
        do {
            let file = try store.create(request); pending = file
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--maintenance-request", file.path]
            config.createsNewApplicationInstance = true
            config.activates = true
            if case .finishSetup = request { config.activates = false }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.openApplication(at: prepared.0, configuration: config) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if app != nil { continuation.resume(returning: ()) }
                    else { continuation.resume(throwing: CocoaError(.executableNotLoadable)) }
                }
            }
        } catch {
            if let pending { try? FileManager.default.removeItem(at: pending) }
            if let staging = prepared.1 { try? FileManager.default.removeItem(at: staging) }
            throw error
        }
        // Settings hands uninstall, update and maintenance over; only background cleanup keeps it open.
        if case .finishSetup = request {} else if Runtime.hasStarted { Runtime.shared.closeSettings() }
    }

    nonisolated static func verify(_ app: URL) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == identifier else { throw CocoaError(.executableNotLoadable) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess else { throw UpdateError.integrity }
    }
}
