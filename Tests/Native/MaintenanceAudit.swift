import AppKit
import FluentKit
import FluentIMECore

@main struct MaintenanceAudit {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        final class Installation: MaintenanceInstallation {
            var hasInstallerPayload = true
            var choice: Bool?
            var completion: ((Result<Void, Error>) -> Void)?
            func remove(keepData: Bool, completion: @escaping (Result<Void, Error>) -> Void) { choice = keepData; self.completion = completion }
        }
        func pump() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2)) }
        let windows = NSApp.windows.count
        // Uninstall is windowless: it carries the keep-data choice, blocks quitting while it runs, then quits.
        for keep in [true, false] {
            let fixture = Installation(); var finished = false, reported: Error?
            let tasks = MaintenanceTasks(installation: fixture, report: { reported = $0 }, finish: { finished = true })
            tasks.handle(.uninstall(keepData: keep)); pump()
            precondition(fixture.choice == keep, "Uninstall did not carry the keep-data choice")
            precondition(tasks.busy && !tasks.canTerminate && !finished)
            fixture.completion?(.success(())); pump()
            precondition(!tasks.busy && finished && reported == nil)
        }
        let failed = Installation(); var failedFinish = false, failure: Error?
        let failing = MaintenanceTasks(installation: failed, report: { failure = $0 }, finish: { failedFinish = true })
        failing.handle(.uninstall(keepData: true)); failed.completion?(.failure(CocoaError(.fileWriteNoPermission))); pump()
        precondition(!failing.busy && failedFinish && failure != nil, "A failed uninstall must be reported before quitting")
        // An update without a payload is reported instead of installing anything.
        let empty = Installation(); empty.hasInstallerPayload = false; var updateFailure: Error?
        MaintenanceTasks(installation: empty, report: { updateFailure = $0 }, finish: {}).applyBundledUpdate()
        precondition(updateFailure != nil)
        // The guide request is handled by the setup window, not by these tasks.
        let guide = Installation(); var guideFinished = false
        let showing = MaintenanceTasks(installation: guide, report: { _ in }, finish: { guideFinished = true })
        showing.handle(.show); pump()
        precondition(!showing.busy && !guideFinished && guide.choice == nil)
        precondition(NSApp.windows.count == windows, "Update and uninstall must not open windows")
        // A call in the input-method process must not execute maintenance directly.
        var rejected = false
        InputMethodInstallation.shared.remove(keepData: false) { if case .failure = $0 { rejected = true } }
        precondition(rejected)
        InputMethodInstallation.shared.install { result in if case .success = result { preconditionFailure("Input method executed installer directly") } }
        print("Maintenance passed: \(L10n.locale.identifier), windowless uninstall with keep/remove choice, failure report, guide hand-off and process boundary")
    }
}
