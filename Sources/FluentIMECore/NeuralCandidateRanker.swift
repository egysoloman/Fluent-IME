import Foundation
import CoreML

public final class RankingTicket {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public protocol CandidateReranking: AnyObject {
    @discardableResult func rank(context: String, candidates: [Candidate], completion: @escaping ([Int]?) -> Void) -> RankingTicket
}

public enum CandidateRanking {
    public static func eligible(_ text: String) -> Bool {
        (1...8).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy(ChineseTokenizer.isHan)
    }
    /// Only compare equal-length Chinese candidates, retaining Rime's ordering
    /// unless the model has a clear margin. User-dictionary rank remains a prior.
    public static func order(candidates: [Candidate], scores: [Double?]) -> [Int] {
        var order = Array(candidates.indices)
        let groups = Dictionary(grouping: candidates.indices.filter { eligible(candidates[$0].text) && $0 < scores.count && scores[$0]?.isFinite == true }, by: { candidates[$0].text.unicodeScalars.count })
        for group in groups.values where group.count > 1 {
            let slots = group.sorted()
            func score(_ index: Int) -> Double { scores[index]! - 0.35 * Double(index) }
            let sorted = slots.sorted { score($0) == score($1) ? $0 < $1 : score($0) > score($1) }
            guard score(sorted[0]) - score(slots[0]) >= 0.8 else { continue }
            for (slot, candidate) in zip(slots, sorted) { order[slot] = candidate }
        }
        return order
    }
}

/// Offline native inference. One serial worker bounds CPU/ANE work across clients.
/// No text, scores or context are persisted or transmitted.
public final class CoreMLCandidateRanker: CandidateReranking {
    public struct Diagnostics {
        public var ready = false
        public var failed = false
        public var scored = 0
        public var applied = 0
        public var milliseconds = 0.0
    }
    public static let statusChanged = Notification.Name("FluentIMERankerStatusChanged")
    private let statusLock = NSLock()
    private var status = Diagnostics()
    public var diagnostics: Diagnostics { statusLock.lock(); defer { statusLock.unlock() }; return status }
    private func updateStatus(_ update: (inout Diagnostics) -> Void) {
        statusLock.lock(); update(&status); statusLock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.statusChanged, object: self) }
    }
    public func recordApplied() { updateStatus { $0.applied += 1 } }
    private let queue = DispatchQueue(label: "org.fluentime.transformer", qos: .userInitiated)
    private let modelURL: URL
    private let vocabularyURL: URL
    private var model: MLModel?
    private var tokenizer: ChineseTokenizer?
    private var unavailable = false
    public init(modelURL: URL, vocabularyURL: URL) { self.modelURL = modelURL; self.vocabularyURL = vocabularyURL }
    public func prewarm() {
        queue.async { [weak self] in
            guard let self else { return }
            do { _ = try self.load() } catch { self.unavailable = true; self.updateStatus { $0.failed = true } }
        }
    }
    private func load() throws -> (MLModel, ChineseTokenizer) {
        if let model, let tokenizer { return (model, tokenizer) }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
        let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try MLModel.compileModel(at: modelURL)
        let loaded = try MLModel(contentsOf: compiled, configuration: config)
        let tokens = try ChineseTokenizer(vocabularyURL: vocabularyURL)
        model = loaded; tokenizer = tokens
        // Warm up before a key requests real scoring; work never runs on the UI thread.
        _ = try score(model: loaded, tokenizer: tokens, context: "", texts: ["中文"], ticket: RankingTicket())
        updateStatus { $0.ready = true }
        return (loaded, tokens)
    }
    @discardableResult public func rank(context: String, candidates: [Candidate], completion: @escaping ([Int]?) -> Void) -> RankingTicket {
        let ticket = RankingTicket()
        queue.async { [weak self] in
            guard let self, !ticket.isCancelled, !self.unavailable else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            do {
                let (model, tokenizer) = try self.load()
                guard !ticket.isCancelled else { DispatchQueue.main.async { completion(nil) }; return }
                let started = ProcessInfo.processInfo.systemUptime
                let scores = try self.score(model: model, tokenizer: tokenizer, context: context, texts: candidates.map(\.text), ticket: ticket)
                if !ticket.isCancelled { self.updateStatus { $0.scored += 1; $0.milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000 } }
                let order = ticket.isCancelled ? nil : CandidateRanking.order(candidates: candidates, scores: scores)
                DispatchQueue.main.async { completion(order) }
            } catch {
                // Fail closed to the unmodified Rime result; never log user input.
                self.unavailable = true; self.updateStatus { $0.failed = true }
                DispatchQueue.main.async { completion(nil) }
            }
        }
        return ticket
    }
    private func score(model: MLModel, tokenizer: ChineseTokenizer, context: String, texts: [String], ticket: RankingTicket) throws -> [Double?] {
        struct Row { let ids: [Int32]; let position: Int; let target: Int32; let owner: Int }
        var rows: [Row] = []
        let prefix = Array(tokenizer.encode(context).suffix(20))
        var counts = Array(repeating: 0, count: texts.count)
        for (owner, text) in texts.enumerated() where CandidateRanking.eligible(text) {
            let tokens = tokenizer.encode(text)
            guard !tokens.contains(tokenizer.unknown), !tokens.isEmpty else { continue }
            let full = [tokenizer.cls] + prefix + tokens + [tokenizer.sep]
            for offset in tokens.indices {
                var masked = full; let position = 1 + prefix.count + offset
                masked[position] = tokenizer.mask
                rows.append(Row(ids: masked, position: position, target: tokens[offset], owner: owner)); counts[owner] += 1
            }
        }
        var sums = Array(repeating: 0.0, count: texts.count)
        for start in stride(from: 0, to: rows.count, by: 8) {
            if ticket.isCancelled { return Array(repeating: nil, count: texts.count) }
            let batch = Array(rows[start..<min(start + 8, rows.count)])
            let ids = try MLMultiArray(shape: [8,32], dataType: .int32)
            let mask = try MLMultiArray(shape: [8,32], dataType: .int32)
            let positions = try MLMultiArray(shape: [8], dataType: .int32)
            let targets = try MLMultiArray(shape: [8], dataType: .int32)
            for rowIndex in 0..<8 {
                let row = batch[min(rowIndex, batch.count - 1)]
                for token in 0..<32 {
                    ids[rowIndex * 32 + token] = NSNumber(value: token < row.ids.count ? row.ids[token] : 0)
                    mask[rowIndex * 32 + token] = NSNumber(value: token < row.ids.count ? 1 : 0)
                }
                positions[rowIndex] = NSNumber(value: row.position); targets[rowIndex] = NSNumber(value: row.target)
            }
            let inputs = try MLDictionaryFeatureProvider(dictionary: ["input_ids":ids,"attention_mask":mask,"positions":positions,"targets":targets])
            let output = try model.prediction(from: inputs)
            guard let scores = output.featureValue(for: "token_scores")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
            for (index, row) in batch.enumerated() { sums[row.owner] += scores[index].doubleValue }
        }
        return texts.indices.map { counts[$0] > 0 && sums[$0].isFinite ? sums[$0] / Double(counts[$0]) : nil }
    }
}
