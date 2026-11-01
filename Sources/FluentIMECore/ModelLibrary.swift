import Foundation
import CoreML

public enum ModelImportError: LocalizedError {
    case grammar, transformer
    public var errorDescription: String? {
        switch self {
        case .grammar: return L10n.modelsInvalidGrammar
        case .transformer: return L10n.modelsInvalidTransformer
        }
    }
}

/// User models live outside the signed application and survive app updates.
/// Selection is committed only after a complete, validated copy is ready.
public final class ModelLibrary {
    public struct Selection: Codable, Equatable {
        public var grammar: String?
        public var transformer: String?
        public init(grammar: String? = nil, transformer: String? = nil) {
            self.grammar = grammar; self.transformer = transformer
        }
    }
    public let root: URL
    public init(root: URL) { self.root = root }
    public var selection: Selection {
        (try? JSONDecoder().decode(Selection.self, from: Data(contentsOf: root.appendingPathComponent("selection.json")))) ?? Selection()
    }
    public func directory(for identifier: String?) -> URL? {
        guard let identifier, UUID(uuidString: identifier) != nil else { return nil }
        return root.appendingPathComponent(identifier, isDirectory: true)
    }
    public var transformerDirectory: URL? { directory(for: selection.transformer) }
    public var grammarURL: URL? { directory(for: selection.grammar)?.appendingPathComponent("model.gram") }
    private func save(_ selection: Selection) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(selection).write(to: root.appendingPathComponent("selection.json"), options: .atomic)
    }
    public func restoreBundled(grammar: Bool) throws {
        var value = selection
        if grammar { value.grammar = nil } else { value.transformer = nil }
        try save(value)
    }
    @discardableResult public func importGrammar(from source: URL) throws -> URL {
        try importModel { destination in
            let target = destination.appendingPathComponent("model.gram")
            try FileManager.default.copyItem(at: source, to: target)
            try Self.validateGrammar(at: target)
            var value = selection; value.grammar = destination.lastPathComponent; try save(value)
        }
    }
    @discardableResult public func importTransformer(from source: URL) throws -> URL {
        try importModel { destination in
            let files = FileManager.default
            let models = try files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                .filter { ["mlmodelc", "mlpackage", "mlmodel"].contains($0.pathExtension) }
            guard models.count == 1,
                  let vocab = ["chinese-context-vocab.txt", "vocab.txt"].map({ source.appendingPathComponent($0) }).first(where: { files.fileExists(atPath: $0.path) }) else { throw ModelImportError.transformer }
            let compiled = models[0].pathExtension == "mlmodelc" ? models[0] : try MLModel.compileModel(at: models[0])
            defer { if compiled != models[0] { try? files.removeItem(at: compiled) } }
            try files.copyItem(at: compiled, to: destination.appendingPathComponent("ChineseContextScorer.mlmodelc"))
            try files.copyItem(at: vocab, to: destination.appendingPathComponent("chinese-context-vocab.txt"))
            try Self.validateTransformer(in: destination)
            var value = selection; value.transformer = destination.lastPathComponent; try save(value)
        }
    }
    private func importModel(_ populate: (URL) throws -> Void) throws -> URL {
        let destination = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do { try populate(destination); return destination }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    /// octagram's mmap format: 44-byte metadata, relative array offset, uint32 Darts units.
    public static func validateGrammar(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 44, data.prefix(32).starts(with: Array("Rime::Grammar/1.0\0".utf8)) else { throw ModelImportError.grammar }
        try data.withUnsafeBytes { bytes in
            func word(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            let count = Int(word(36)), start = 40 + Int(Int32(bitPattern: word(40)))
            guard start >= 44, start <= data.count, count >= 256, count % 256 == 0,
                  count <= (data.count - start) / 4 else { throw ModelImportError.grammar }
            for index in 0..<count {
                let unit = word(start + index * 4)
                if unit & 0x80000000 != 0 { continue } // leaf: score, not an offset
                let offset = UInt64(unit >> 10) << ((unit & 0x200) >> 6)
                guard UInt64(index) ^ offset < UInt64(count) else { throw ModelImportError.grammar }
            }
        }
    }
    public static func validateTransformer(in directory: URL) throws {
        let vocabulary = try String(contentsOf: directory.appendingPathComponent("chinese-context-vocab.txt"), encoding: .utf8).components(separatedBy: "\n")
        guard vocabulary.first == "[PAD]", ["[CLS]", "[SEP]", "[MASK]", "[UNK]", "中", "文"].allSatisfy(vocabulary.contains), vocabulary.count < 1_000_000 else { throw ModelImportError.transformer }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: directory.appendingPathComponent("ChineseContextScorer.mlmodelc"), configuration: config)
        let shapes: [String: [NSNumber]] = ["input_ids": [8,32], "attention_mask": [8,32], "positions": [8], "targets": [8]]
        guard Set(model.modelDescription.inputDescriptionsByName.keys) == Set(shapes.keys),
              let output = model.modelDescription.outputDescriptionsByName["token_scores"]?.multiArrayConstraint,
              output.shape == [8], [.float16, .float32, .double].contains(output.dataType) else { throw ModelImportError.transformer }
        var inputs: [String: MLMultiArray] = [:]
        for (name, shape) in shapes {
            guard let spec = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint, spec.shape == shape, spec.dataType == .int32 else { throw ModelImportError.transformer }
            let value = try MLMultiArray(shape: shape, dataType: .int32)
            for index in 0..<value.count { value[index] = 0 }
            inputs[name] = value
        }
        for row in 0..<8 {
            for (column, token) in ["[CLS]", "[MASK]", "[SEP]"].enumerated() {
                inputs["input_ids"]![row * 32 + column] = NSNumber(value: vocabulary.firstIndex(of: token)!)
                inputs["attention_mask"]![row * 32 + column] = 1
            }
            inputs["positions"]![row] = 1
            inputs["targets"]![row] = NSNumber(value: vocabulary.firstIndex(of: "中")!)
        }
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
        guard let scores = result.featureValue(for: "token_scores")?.multiArrayValue, scores.count == 8,
              (0..<8).allSatisfy({ scores[$0].doubleValue.isFinite }) else { throw ModelImportError.transformer }
    }
    /// Rime resolves user files before shared files. Only replace the app-owned
    /// override at startup, after the previous process released its mapped model.
    public func prepareGrammar(in userDirectory: URL) throws {
        let files = FileManager.default
        let marker = userDirectory.appendingPathComponent(".fluent-model-selection")
        let target = userDirectory.appendingPathComponent("wanxiang-lts-zh-hans.gram")
        if let source = grammarURL {
            if (try? String(contentsOf: marker, encoding: .utf8)) == selection.grammar, files.fileExists(atPath: target.path) { return }
            try files.createDirectory(at: userDirectory, withIntermediateDirectories: true)
            let temporary = userDirectory.appendingPathComponent(UUID().uuidString + ".gram")
            defer { try? files.removeItem(at: temporary) }
            try files.copyItem(at: source, to: temporary)
            if files.fileExists(atPath: target.path) {
                if !files.fileExists(atPath: marker.path) {
                    try files.copyItem(at: target, to: userDirectory.appendingPathComponent("previous-" + UUID().uuidString + ".gram"))
                }
                _ = try files.replaceItemAt(target, withItemAt: temporary)
            } else { try files.moveItem(at: temporary, to: target) }
            try selection.grammar!.write(to: marker, atomically: true, encoding: .utf8)
        } else if files.fileExists(atPath: marker.path) {
            if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
            try files.removeItem(at: marker)
        }
    }
}
