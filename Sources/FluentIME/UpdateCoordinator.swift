import AppKit
import FluentKit
import FluentIMECore

protocol IMEUpdateService {
    func latest(channel: UpdateChannel) async throws -> GitHubRelease?
    func history(channel: UpdateChannel) async throws -> [GitHubRelease]
    func download(_ release: GitHubRelease, to directory: URL, progress: (@Sendable (UpdateDownloadProgress) -> Void)?) async throws -> URL
}
extension GitHubUpdateService: IMEUpdateService {}

@MainActor final class UpdateCoordinator {
    static let shared = UpdateCoordinator()
    static let changed = Notification.Name("FluentIMEUpdateStateChanged")
    enum State { case idle, checking, available(String), current, downloading(Int64, Int64), verifying, opening, opened, cancelled, failed(String) }
    private(set) var state: State = .idle { didSet { NotificationCenter.default.post(name: Self.changed, object: self) } }
    private(set) var connectionFailed = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var release: GitHubRelease?
    private(set) var latestRelease: GitHubRelease?
    private(set) var history: [GitHubRelease] = []
    private(set) var historyLoading = false
    private(set) var historyError: String?
    private var historyTask: Task<Void, Never>?
    private var historyGeneration = 0
    private var automaticTimer: Timer?
    var automaticChecks: Bool {
        get { defaults.object(forKey: "updateAutomaticChecks") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "updateAutomaticChecks"); notify()
            if newValue { checkAutomaticallyIfDue() }
        }
    }
    func startAutomaticChecks() {
        guard automaticTimer == nil else { return }
        automaticTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomaticallyIfDue() }
        }
        automaticTimer?.tolerance = 300
        checkAutomaticallyIfDue()
    }
    func checkAutomaticallyIfDue(now: Date = Date()) {
        guard automaticChecks, !busy,
              defaults.object(forKey: "updateLastAttempt").flatMap({ $0 as? Date }).map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return }
        channel = UpdateChannel(rawValue: defaults.string(forKey: "updateChannel") ?? "") ?? .stable
        check()
    }
    private static func isConnectionFailure(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed].contains(error.code)
    }
    private static func message(_ error: Error) -> String {
        if error is URLError { return L10n.updateConnectionFailed }
        return error.localizedDescription
    }
    private let defaults: UserDefaults
    private(set) var channel: UpdateChannel
    private(set) var lastChecked: Date?
    var canChangeChannel: Bool {
        switch state { case .downloading, .verifying, .opening: return false; default: return true }
    }
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: self) }
    func selectChannel(_ channel: UpdateChannel) {
        guard canChangeChannel, self.channel != channel else { return }
        generation += 1; task?.cancel(); task = nil
        historyGeneration += 1; historyTask?.cancel(); historyTask = nil
        self.channel = channel; defaults.set(channel.rawValue, forKey: "updateChannel")
        history = []; historyError = nil; historyLoading = false; latestRelease = nil; release = nil; state = .idle
        check(); loadHistory()
    }
    func loadHistory() {
        guard !historyLoading else { return }
        historyGeneration += 1; let request = historyGeneration; let channel = channel
        historyLoading = true; historyError = nil; notify()
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let records = try await service.history(channel: channel); try Task.checkCancellation()
                guard request == historyGeneration else { return }
                history = records
            } catch { if request == historyGeneration, !Task.isCancelled { historyError = Self.message(error) } }
            guard request == historyGeneration else { return }
            historyLoading = false; historyTask = nil; notify()
        }
    }
    private let service: any IMEUpdateService
    init(service: any IMEUpdateService = GitHubUpdateService(), defaults: UserDefaults? = nil) {
        self.service = service; self.defaults = defaults ?? (InstallerLifecycle.isMaintenance ? UserDefaults(suiteName: FluentProduct.current.bundleID)! : .standard)
        channel = UpdateChannel(rawValue: self.defaults.string(forKey: "updateChannel") ?? "") ?? .stable
        lastChecked = self.defaults.object(forKey: "updateLastChecked") as? Date
        // Until this session checks, show the result of the last check for the same channel.
        if lastChecked != nil, self.defaults.string(forKey: "updateLatestChannel") == channel.rawValue,
           let data = self.defaults.data(forKey: "updateLatestRelease"), let cached = try? JSONDecoder().decode(GitHubRelease.self, from: data) {
            latestRelease = cached
            if cached.isNewer(than: currentVersion, channel: channel) { release = cached; state = .available(cached.version) } else { state = .current }
        }
    }
    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var busy: Bool {
        switch state { case .checking, .downloading, .verifying, .opening: return true; default: return false }
    }
    var canInstall: Bool { release != nil && !busy }
    func check() {
        guard !busy else { return }
        defaults.set(Date(), forKey: "updateLastAttempt")
        generation += 1; let request = generation; let channel = channel; release = nil; state = .checking
        loadHistory()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let latest = try await service.latest(channel: channel); try Task.checkCancellation()
                guard request == generation else { return }
                latestRelease = latest; lastChecked = Date(); defaults.set(lastChecked, forKey: "updateLastChecked")
                defaults.set(latest.flatMap { try? JSONEncoder().encode($0) }, forKey: "updateLatestRelease"); defaults.set(channel.rawValue, forKey: "updateLatestChannel")
                if let latest, latest.isNewer(than: currentVersion, channel: channel) || (InstallerLifecycle.isMaintenance && !InputMethodInstallation.shared.isPresent) { release = latest; state = .available(latest.version) }
                else { state = latest == nil ? .failed(L10n.updateNoRelease) : .current }
            } catch { if request == generation, !Task.isCancelled { connectionFailed = Self.isConnectionFailure(error); state = .failed(Self.message(error)) } }
            if request == generation { task = nil }
        }
    }
    func cancel() {
        if case .opening = state { return }
        generation += 1; task?.cancel(); task = nil; state = .cancelled
    }
    func install() {
        guard let release, !busy else { return }
        generation += 1; let request = generation
        state = .downloading(0, release.installer(for: .current)?.size ?? 0)
        let previous = InstallerLifecycle.isInstaller ? [Bundle.main.bundleURL.path] + InstallerLifecycle.previousInstallers : []
        let waitForParent = InstallerLifecycle.isMaintenance
        task = Task { [weak self] in
            guard let self else { return }
            let directory = InputMethodInstallation.shared.files.support.appendingPathComponent("Updates/" + UUID().uuidString)
            do {
                let file = try await service.download(release, to: directory) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == request, case .downloading = self.state else { return }
                        switch progress {
                        case .downloading(let received, let total): self.state = .downloading(received, total)
                        case .verifying: self.state = .verifying
                        }
                    }
                }
                try Task.checkCancellation(); guard request == generation else { throw CancellationError() }
                state = .opening
                if InstallerLifecycle.isMaintenance {
                    let launcher = Task.detached { try MaintenanceUpdateExecutor.launch(file, version: release.version, previous: previous, waitForParent: waitForParent) }
                    try await withTaskCancellationHandler(operation: { try await launcher.value }, onCancel: { launcher.cancel() })
                } else {
                    try await MaintenanceClient.launch(.update(file: file, version: release.version))
                }
                guard request == generation else { return }
                self.release = nil; state = .opened
                if waitForParent { NSApp.terminate(nil) }
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if request == generation, !Task.isCancelled { connectionFailed = Self.isConnectionFailure(error); state = .failed(Self.message(error)) }
            }
            if request == generation { task = nil }
        }
    }
}
