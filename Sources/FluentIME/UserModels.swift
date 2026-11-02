import AppKit
import FluentIMECore

enum UserModels {
    private static var isImporting = false
    static let library = ModelLibrary(root: FluentProduct.current.supportDirectory.appendingPathComponent("Models", isDirectory: true))
    static func download(grammar: Bool) {
        // Downloads remain user-initiated in the browser; importing validates
        // the actual model rather than trusting its file name or source URL.
        let address = grammar ? "https://github.com/amzxyz/rime-wanxiang-data/releases/tag/LTS" : "https://github.com/egysoloman/Fluent-IME/releases/latest/download/Fluent-IME-Transformer.zip"
        NSWorkspace.shared.open(URL(string: address)!)
    }
    static func chooseImport(grammar: Bool, in root: NSView, completion: @escaping (String) -> Void) {
        guard !isImporting, let window = root.window else { return }
        isImporting = true
        let chooser = NSOpenPanel()
        chooser.title = grammar ? L10n.modelsImportGrammar : L10n.modelsImportTransformer
        chooser.message = grammar ? L10n.modelsGrammarFormat : L10n.modelsTransformerFormat
        chooser.canChooseDirectories = !grammar; chooser.canChooseFiles = grammar
        chooser.allowsMultipleSelection = false
        chooser.beginSheetModal(for: window) { result in
            guard result == .OK, let url = chooser.url else { isImporting = false; return }
            completion(L10n.modelsValidating)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { if grammar { _ = try library.importGrammar(from: url) } else { _ = try library.importTransformer(from: url) } }
                DispatchQueue.main.async {
                    isImporting = false
                    switch result {
                    case .success:
                        completion(L10n.modelsRestartHint)
                        offerRestart(in: root)
                    case .failure(let error):
                        completion("")
                        MaintenanceDialogs.showError(error, in: root)
                    }
                }
            }
        }
    }
    static func restore(grammar: Bool, in root: NSView, completion: @escaping (String) -> Void) {
        guard !isImporting else { return }
        do {
            try library.restoreBundled(grammar: grammar)
            completion(L10n.modelsRestartHint)
            offerRestart(in: root)
        } catch { MaintenanceDialogs.showError(error, in: root) }
    }
    private static func offerRestart(in root: NSView) {
        MaintenanceDialogs.present(in: root, title: L10n.modelsTitle, message: L10n.modelsRestartHint,
                                   primary: L10n.modelsRestart, emphasizePrimary: true) { _ in
            try InputMethodInstallation.shared.relaunchAndQuit()
        }
    }
}
