import Foundation
import FluentIMECore

@main struct GrammarBenchmark {
    static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1])
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("FluentIME-Grammar-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:scratch) }
        let shared=scratch.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at:shared,withIntermediateDirectories:true)
        for name in ["fluent_pinyin.schema.yaml","fluent_pinyin.dict.yaml","fluent_symbols.dict.yaml","fluent_emoji.dict.yaml","symbols.yaml"] {
            let from=root.appendingPathComponent("Resources/Rime/"+name)
            if FileManager.default.fileExists(atPath:from.path) { try FileManager.default.copyItem(at:from,to:shared.appendingPathComponent(name)) }
        }
        try FileManager.default.copyItem(at:root.appendingPathComponent("Vendor/rime-pinyin-simp/pinyin_simp.dict.yaml"),to:shared.appendingPathComponent("pinyin_simp.dict.yaml"))
        try FileManager.default.linkItem(at:root.appendingPathComponent("Vendor/wanxiang/wanxiang-lts-zh-hans.gram"),to:shared.appendingPathComponent("wanxiang-lts-zh-hans.gram"))
        var schema=try String(contentsOf:shared.appendingPathComponent("fluent_pinyin.schema.yaml"))
        schema=schema.replacingOccurrences(of:"schema_id: fluent_pinyin",with:"schema_id: fluent_pinyin_gram")
        schema += "\ngrammar:\n  language: wanxiang-lts-zh-hans\n  collocation_max_length: 8\n  collocation_min_length: 2\n  collocation_penalty: -15\n  non_collocation_penalty: -5\n  weak_collocation_penalty: -100\n  rear_penalty: -10\n"
        schema=schema.replacingOccurrences(of:"translator:\n",with:"translator:\n  contextual_suggestions: false\n  max_homophones: 8\n")
        try schema.write(to:shared.appendingPathComponent("fluent_pinyin_gram.schema.yaml"),atomically:true,encoding:.utf8)
        try "config_version: '1.5'\nschema_list:\n  - schema: fluent_pinyin\n  - schema: fluent_pinyin_gram\nmenu:\n  page_size: 7\n".write(to:shared.appendingPathComponent("default.yaml"),atomically:true,encoding:.utf8)
        let engine=try RimeEngine(sharedDirectory:shared,userDirectory:scratch.appendingPathComponent("user"))
        let inputs=["nihaoshijie","wozaixuexizhongwen","zhuzailiwu","qingbangwodakaichuanghu","jintiandetianqihenhao","womenmingtianqubeijing","zhejianshiqingxuyaokaolv","woxiangchiyiwanniuroumian","qinglaoshiduoduozhidao","wentiyijingdedaojiejue","zhexiangzhengcekaishishishi","rengongzhinengshurufa","chulejiudian","geixinrenjieshao"]
        var rows:[[String:Any]]=[]
        for schemaID in ["fluent_pinyin","fluent_pinyin_gram"] {
            let session=try engine.makeSession()
            let loadStart=CFAbsoluteTimeGetCurrent(); precondition(session.selectSchema(schemaID))
            let loadMS=(CFAbsoluteTimeGetCurrent()-loadStart)*1000
            for trial in 0..<3 {
            for input in inputs {
                session.clear();var timings:[Double]=[]
                for byte in input.utf8 { let start=CFAbsoluteTimeGetCurrent();session.process(key:Int32(byte));_ = session.composition;timings.append((CFAbsoluteTimeGetCurrent()-start)*1000) }
                timings.sort();rows.append(["pass":trial,"schema":schemaID,"input":input,"candidates":session.composition.candidates.prefix(3).map(\.text),"key_p95_ms":timings[min(timings.count-1,Int(Double(timings.count)*0.95))],"load_ms":loadMS])
            }
            }
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("artifacts/grammar-benchmark.json"))
        for row in rows { print(row["schema"]!,row["input"]!,row["candidates"]!,row["key_p95_ms"]!) }
    }
}
