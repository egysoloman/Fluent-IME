import Foundation
import FluentIMECore

@main struct ModelImportProbe {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-ModelProbe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let library = ModelLibrary(root: temporary.appendingPathComponent("Models"))
        try library.importGrammar(from: resources.appendingPathComponent("Rime/wanxiang-lts-zh-hans.gram"))
        try library.prepareGrammar(in: temporary.appendingPathComponent("Rime"))
        let engine = try RimeEngine(sharedDirectory: resources.appendingPathComponent("Rime"), userDirectory: temporary.appendingPathComponent("Rime"))
        let session = try engine.makeSession()
        for byte in "nihao".utf8 { _ = session.process(key: Int32(byte)) }
        precondition(!session.composition.candidates.isEmpty)
        print("Imported grammar: real Rime query passed")
        try library.importTransformer(from: resources.appendingPathComponent("Models"))
        precondition(library.transformerDirectory != nil)
        print("Imported Transformer: Core ML interface and prediction passed")
    }
}
