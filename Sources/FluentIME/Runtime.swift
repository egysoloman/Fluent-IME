import AppKit
import FluentIMECore

final class Runtime {
    static let shared = Runtime()
    private(set) static var hasStarted = false
    lazy var engine: Result<RimeEngine, Error> = makeEngine()
    private var setup: SetupWindowController?
    private var settings: SettingsWindowController?

    init() {
        Self.hasStarted = true
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--render-") }) {
            ClipboardHistory.shared.setRetention(TimeInterval(Preferences.shared.clipboardRetention))
            ClipboardHistory.shared.setRecording(Preferences.shared.clipboardRecording)
        }
    }
    private func makeEngine() -> Result<RimeEngine, Error> {
        if Preferences.shared.enabledInputModes.contains(where: { $0.isChinese && LanguagePreferences($0).neuralRanking }) {
            NeuralRuntime.shared.ranker?.prewarm()
        }
        return Result {
            let shared = Bundle.main.resourceURL!.appendingPathComponent("Rime", isDirectory: true)
            var user = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(FluentProduct.current.supportFolder + "/Rime", isDirectory: true)
            if CommandLine.arguments.contains("--render-preview") || CommandLine.arguments.contains("--render-components") {
                // Offline rendering must never compete with the active IMK server's LevelDB lock.
                user = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-Preview-" + UUID().uuidString)
            }
            try UserModels.library.prepareGrammar(in: user)
            return try RimeEngine(sharedDirectory: shared, userDirectory: user)
        }
    }

    func showInstallationCleanupError(_ error: Error) {
        showSettings()
        if let root = settings?.window?.contentView { MaintenanceDialogs.showError(error, in: root) }
    }
    func showSettings() {
        if !Preferences.shared.setupCompleted && !CommandLine.arguments.contains(where: { $0.hasPrefix("--render-") }) {
            if setup == nil { setup = SetupWindowController(onComplete: { [weak self] in self?.showSettings() }) }
            setup?.showWindow(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        do {
            if settings == nil { settings = try SettingsWindowController(engine: engine.get()) }
            if settings?.window?.isMiniaturized == true { settings?.window?.deminiaturize(nil) }
            settings?.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch { showError(error) }
    }

    func closeSettings() { settings?.close() }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.errorStartup
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

final class NeuralRuntime {
    static let shared = NeuralRuntime()
    let ranker: CoreMLCandidateRanker?
    private init() {
        let directory = UserModels.library.transformerDirectory ?? Bundle.main.resourceURL?.appendingPathComponent("Models")
        if let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("ChineseContextScorer.mlmodelc").path) {
            ranker = CoreMLCandidateRanker(modelURL: directory.appendingPathComponent("ChineseContextScorer.mlmodelc"), vocabularyURL: directory.appendingPathComponent("chinese-context-vocab.txt"))
        } else { ranker = nil }
    }
}
