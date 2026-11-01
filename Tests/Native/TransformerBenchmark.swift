import Foundation
import AppKit
import FluentIMECore

@main
struct TransformerBenchmark {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-ModelBenchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let engine = try RimeEngine(sharedDirectory: root.appendingPathComponent("dist/Fluent IME.app/Contents/Resources/Rime"), userDirectory: scratch)
        let ranker = CoreMLCandidateRanker(modelURL: root.appendingPathComponent("Resources/Models/ChineseContextScorer.mlpackage"), vocabularyURL: root.appendingPathComponent("Resources/Models/chinese-context-vocab.txt"))
        func rank(_ context: String, _ words: [Candidate]) -> (order:[Int]?, ms:Double) {
            var finished = false, result: [Int]?
            let start = CFAbsoluteTimeGetCurrent()
            ranker.rank(context: context, candidates: words) { result = $0; finished = true }
            while !finished && CFAbsoluteTimeGetCurrent() - start < 30 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001)) }
            return (result, (CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let cold = rank("请老师多多", [Candidate("知道"),Candidate("指导")])
        guard cold.order != nil else { fatalError("Core ML scorer failed") }
        let cases = [
            ("请老师多多", "zhidao", "指导"), ("这个消息我已经", "zhidao", "知道"),
            ("医生让我按时", "chiyao", "吃药"), ("这本书讲解了", "lishi", "历史"),
            ("门口的水管又开始", "loushui", "漏水"), ("这里的风景真", "mei", "美"),
            ("这道数学题很", "nan", "难"), ("他在公司担任", "zhuguan", "主管"),
            ("这只是你的", "zhuguan", "主观"), ("请在合同上", "qianming", "签名"),
            ("问题已经得到", "jiejue", "解决"), ("我们应该尊重", "shishi", "事实"),
            ("这项政策开始", "shishi", "实施"), ("他在现场目击了这起", "shigu", "事故"),
            ("请保持", "anjing", "安静"), ("这种方法很", "kexue", "科学"),
            ("孩子需要家长的", "peiban", "陪伴")
        ]
        var records: [[String:Any]] = [], times: [Double] = []
        for (context, pinyin, expected) in cases {
            let session = try engine.makeSession(); session.setOption("disable_user_dict", true)
            for byte in pinyin.utf8 { session.process(key: Int32(byte)) }
            let candidates = session.composition.candidates
            var finalOrder: [Int] = []
            for _ in 0..<10 {
                let result = rank(context, candidates)
                guard let order = result.order else { fatalError("Scoring failed") }
                finalOrder = order; times.append(result.ms)
            }
            records.append(["context":context,"pinyin":pinyin,"expected":expected,"before":candidates.map(\.text),"after":finalOrder.map{candidates[$0].text},"target_in_top7":candidates.contains{$0.text == expected}])
        }
        let input = try InputSession(engine: engine, options: { InputOptions(learning: false, neuralRanking: true) }, ranker: ranker)
        var keyTimes: [Double] = []
        for _ in 0..<50 {
            input.cancel(); input.resetContext()
            for character in "nihao zhidao" {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: String(character), charactersIgnoringModifiers: String(character), isARepeat: false, keyCode: 0)!
                let start = CFAbsoluteTimeGetCurrent(); input.handle(event); keyTimes.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
        }
        input.cancel(); input.resetContext()
        func distribution(_ values:[Double]) -> [String:Double] { let sorted=values.sorted(); return ["p50":sorted[sorted.count/2],"p95":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))],"max":sorted.last!] }
        let report: [String:Any] = ["cold_first_rank_ms":cold.ms,"complete_top7_rank_ms":distribution(times),"keypress_handler_ms_excluding_paint":distribution(keyTimes),"cases":records,"note":"Synthetic homophone examples, not a representative accuracy benchmark. Timing includes native tokenization, MLM batches, sorting and main-queue delivery."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: output)
        print(String(data:try JSONSerialization.data(withJSONObject:["cold_ms":cold.ms,"ranking_ms":distribution(times),"key_ms":distribution(keyTimes)],options:.sortedKeys),encoding:.utf8)!)
    }
}
