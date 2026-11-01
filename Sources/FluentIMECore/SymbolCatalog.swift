import Foundation

public enum SymbolKind { case emoji, kaomoji, symbol }

public struct SymbolEntry: Equatable {
    public let text: String
    public let name: String
    public let keywords: String
    public let kind: SymbolKind
    public init(_ text: String, _ name: String, _ keywords: String, _ kind: SymbolKind = .emoji) {
        self.text = text; self.name = name; self.keywords = keywords; self.kind = kind
    }
}

/// Offline catalog. No clipboard monitoring, network search or third-party image requests.
public enum SymbolCatalog {
    private static let favorites: [SymbolEntry] = [
        .init("😊", "微笑", "weixiao smile happy 开心"), .init("😂", "笑哭", "xiaoku laugh tears"),
        .init("🤣", "笑得打滚", "xiaosi laugh rofl"), .init("❤️", "红心", "aixin heart love 爱"),
        .init("😍", "心动", "xindong like love 喜欢"), .init("😒", "不高兴", "bugaoxing unamused"),
        .init("👌", "好的", "haode ok 手势"), .init("😘", "飞吻", "feiwen kiss 亲亲"),
        .init("💕", "两颗心", "aixin heart love 爱"), .init("😁", "开心", "kaixin grin smile"),
        .init("👍", "点赞", "dianzan zan thumb up"), .init("🙌", "举手欢呼", "jushou celebrate"),
        .init("😀", "笑脸", "xiaolian happy smile"), .init("🥰", "幸福", "xingfu love 开心"),
        .init("😎", "酷", "ku cool sunglasses"), .init("🤔", "思考", "sikao think"),
        .init("😭", "大哭", "daku cry sad"), .init("🥹", "感动", "gandong tears"),
        .init("😴", "睡觉", "shuijiao sleep"), .init("😅", "尴尬", "ganga sweat smile"),
        .init("😡", "生气", "shengqi angry"), .init("🤗", "拥抱", "yongbao hug"),
        .init("🤩", "崇拜", "chongbai star eyes"), .init("🫡", "敬礼", "jingli salute"),
        .init("🙏", "谢谢", "xiexie thanks pray"), .init("👏", "鼓掌", "guzhang clap"),
        .init("👋", "挥手", "huishou wave 你好"), .init("✌️", "胜利", "shengli victory peace"),
        .init("🤝", "握手", "woshou handshake"), .init("💪", "加油", "jiayou strong muscle"),
        .init("🐍", "蛇", "she snake 动物"), .init("🐱", "猫", "mao cat 动物"),
        .init("🐶", "狗", "gou dog 动物"), .init("🐼", "熊猫", "xiongmao panda 动物"),
        .init("🐉", "龙", "long dragon 动物"), .init("🦊", "狐狸", "huli fox 动物"),
        .init("🌹", "玫瑰", "meigui rose flower"), .init("🌸", "樱花", "yinghua flower"),
        .init("🌻", "向日葵", "xiangrikui flower"), .init("🍀", "幸运草", "xingyun clover lucky"),
        .init("☀️", "太阳", "taiyang sun"), .init("🌈", "彩虹", "caihong rainbow"),
        .init("🍎", "苹果", "pingguo apple fruit"), .init("🍉", "西瓜", "xigua watermelon"),
        .init("🍓", "草莓", "caomei strawberry"), .init("🍰", "蛋糕", "dangao cake"),
        .init("☕", "咖啡", "kafei coffee"), .init("🧋", "奶茶", "naicha bubble tea"),
        .init("🎉", "庆祝", "qingzhu party"), .init("🎂", "生日", "shengri birthday"),
        .init("🎁", "礼物", "liwu gift"), .init("🎈", "气球", "qiqiu balloon"),
        .init("✨", "闪亮", "shanliang sparkle"), .init("🔥", "火焰", "huoyan fire hot"),
        .init("💯", "满分", "manfen hundred"), .init("✅", "完成", "wancheng done check"),
        .init("🚀", "火箭", "huojian rocket"), .init("💻", "电脑", "diannao computer"),
        .init("📚", "书籍", "shuji books"), .init("🎵", "音乐", "yinyue music"),
        .init("(✿◡‿◡)", "微笑", "weixiao smile", .kaomoji),
        .init("(≧▽≦)", "开心", "kaixin happy", .kaomoji),
        .init("(๑•̀ㅂ•́)و✧", "加油", "jiayou cheer", .kaomoji),
        .init("(づ｡◕‿‿◕｡)づ", "抱抱", "baobao hug", .kaomoji),
        .init("¯\\_(ツ)_/¯", "耸肩", "songjian shrug", .kaomoji),
        .init("(╯°□°)╯︵ ┻━┻", "掀桌", "xianzhuo angry", .kaomoji),
        .init("(T_T)", "哭泣", "kuqi sad cry", .kaomoji),
        .init("/(ㄒoㄒ)/~~", "哭泣", "ku kuqi sad cry", .kaomoji),
        .init("( •̀ ω •́ )✧", "认真", "renzhen focus", .kaomoji),
        .init("(～￣▽￣)～", "悠闲", "youxian relax", .kaomoji),
        .init("(o゜▽゜)o☆", "惊喜", "jingxi surprise", .kaomoji),
        .init("©", "版权", "banquan copyright", .symbol), .init("®", "注册商标", "shangbiao registered", .symbol),
        .init("™", "商标", "shangbiao trademark", .symbol), .init("°", "度", "du degree", .symbol),
        .init("℃", "摄氏度", "sheshidu celsius", .symbol), .init("℉", "华氏度", "huashidu fahrenheit", .symbol),
        .init("±", "正负", "zhengfu plus minus", .symbol), .init("×", "乘", "cheng multiply", .symbol),
        .init("÷", "除", "chu divide", .symbol), .init("≠", "不等于", "budengyu unequal", .symbol),
        .init("≈", "约等于", "yuedengyu approximately", .symbol), .init("∞", "无穷", "wuqiong infinity", .symbol),
        .init("≤", "小于等于", "xiaoyu less", .symbol), .init("≥", "大于等于", "dayu greater", .symbol),
        .init("√", "根号", "genhao root", .symbol), .init("π", "圆周率", "yuanzhoulv pi", .symbol),
        .init("α", "阿尔法", "alpha", .symbol), .init("β", "贝塔", "beta", .symbol),
        .init("μ", "缪", "mu", .symbol), .init("Δ", "德尔塔", "delta", .symbol),
        .init("→", "右箭头", "you jiantou right arrow", .symbol), .init("←", "左箭头", "zuo jiantou left arrow", .symbol),
        .init("↑", "上箭头", "shang jiantou up arrow", .symbol), .init("↓", "下箭头", "xia jiantou down arrow", .symbol),
        .init("¥", "人民币", "renminbi yuan money", .symbol), .init("€", "欧元", "ouyuan euro money", .symbol),
        .init("£", "英镑", "yingbang pound money", .symbol), .init("$", "美元", "meiyuan dollar money", .symbol)
    ]

    private struct Annotation: Decodable { let text: String; let name: String; let keywords: String }
    private static func identity(_ text: String) -> String { text.replacingOccurrences(of: "\u{FE0F}", with: "") }
    public static let entries: [SymbolEntry] = {
        guard let url = Bundle.module.url(forResource: "emoji-search", withExtension: "json"),
              let data = try? Data(contentsOf: url), let annotations = try? JSONDecoder().decode([Annotation].self, from: data) else { return favorites }
        let byGlyph = Dictionary(annotations.map { (identity($0.text), $0) }, uniquingKeysWith: { first, _ in first })
        var result = favorites.map { entry -> SymbolEntry in
            guard entry.kind == .emoji, let extra = byGlyph[identity(entry.text)] else { return entry }
            return SymbolEntry(entry.text, entry.name, entry.keywords + " " + extra.name + " " + extra.keywords)
        }
        let known = Set(favorites.map { identity($0.text) })
        result += annotations.filter { !known.contains(identity($0.text)) }.map { SymbolEntry($0.text, $0.name, $0.keywords) }
        return result
    }()
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
    }
    private struct SearchRecord {
        let entry: SymbolEntry
        let name: String
        let pinyinName: String
        let words: [String]
        let haystack: String
    }
    private static let searchIndex: [SearchRecord] = entries.map { entry in
        let name = normalized(entry.name)
        // Include pinyin for every Chinese annotation, not just a few hand-picked icons.
        let latin = normalized((entry.name + " " + entry.keywords).applyingTransform(.toLatin, reverse: false) ?? "")
        let pinyinName = normalized(entry.name.applyingTransform(.toLatin, reverse: false) ?? "").filter { !$0.isWhitespace && !$0.isPunctuation }
        let words = normalized(entry.keywords + " " + latin).split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).map(String.init) + [pinyinName]
        return SearchRecord(entry: entry, name: name, pinyinName: pinyinName, words: words, haystack: normalized(entry.text + " " + entry.name + " " + entry.keywords) + " " + latin + " " + pinyinName)
    }
    public static func search(_ query: String, kind: SymbolKind? = nil) -> [SymbolEntry] {
        let query = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.isEmpty { return entries.filter { kind == nil || $0.kind == kind } }
        return searchIndex.enumerated().compactMap { index, record -> (Int, Int, SymbolEntry)? in
            if let kind, record.entry.kind != kind { return nil }
            guard tokens.allSatisfy({ record.haystack.contains($0) }) else { return nil }
            let score = identity(record.entry.text) == identity(query) ? 0 : record.name == query || record.pinyinName == tokens.joined() ? 1 : record.words.contains(query) ? 2 : record.name.hasPrefix(query) ? 3 : record.words.contains(where: { $0.hasPrefix(query) }) ? 4 : 5
            return (score, index, record.entry)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
    }

    public static func recent(afterSelecting text: String, existing: [String]) -> [String] {
        // Only catalog symbols are retained; arbitrary clipboard text is never persisted here.
        guard entries.contains(where: { $0.text == text }) else { return existing }
        var seen = Set<String>()
        return Array(([text] + existing).filter { seen.insert($0).inserted }.prefix(24))
    }
}
