import Foundation

/// 「特殊字体」——文字反检测加密。
///
/// 两档强度（可叠加）：
/// 1. 零宽字符（antiDetect）：视觉 100% 不变，挡「纯字符串匹配」；
/// 2. 拆字（antiRadical）：敏感字拆成偏旁部首（「操」→「扌品木」），
///    同时挡住字符串匹配 + Unicode 归一化 + 谐音词库，是纯文本层面最强的
///    中文反检测手段。代价是视觉变化（字变成偏旁）。
enum AntiDetect {

    /// 零宽字符池：零宽空格 / 零宽非连接符 / 零宽连接符。
    /// 刻意不含 U+FEFF（零宽无断空格）：no-break 字符会粘住换行。
    private static let zws: [Character] = ["\u{200B}", "\u{200C}", "\u{200D}"]

    /// 拆字映射表：高频违规/敏感字 → 偏旁部首分解。
    /// 覆盖辱骂、色情、诈骗等类目。拆字后「操」变成「扌品木」三个部件，
    /// 字符串匹配、归一化、谐音词库三层全都失效。
    private static let radicalMap: [Character: String] = [
        // 辱骂
        "操": "扌品木", "你": "亻尔", "妈": "女马", "逼": "辶畐",
        "日": "曰", "草": "艹早", "卧": "臣卜", "槽": "木曹",
        "傻": "亻囟", "滚": "氵衮", "死": "歹匕", "贱": "贝戋",
        "婊": "女表", "狗": "犭句", "猪": "犭者", "驴": "马户",
        "孙": "子小", "废": "广发", "物": "牜勿", "垃": "土立",
        "圾": "土及", "蠢": "春虫", "痴": "疒知", "脑": "月囟",
        "残": "歹戋", "障": "阝章", "货": "亻贝",
        "色": "⺈巴", "鬼": "田儿厶", "娘": "女良", "奶": "女乃",
        "爷": "父卩", "蛋": "疋虫", "鸟": "乌丶", "粪": "米共",
        // 色情
        "性": "忄生", "赌": "贝者", "嫖": "女票", "妓": "女支",
        "鸡": "又鸟", "屌": "尸吊", "屄": "尸穴", "肏": "入肉",
        "黄": "廿由八", "裸": "衤果", "淫": "氵爪壬",
        // 诈骗/赌博
        "骗": "马扁", "诈": "讠乍", "博": "十尃",
        // 其他高频敏感
        "毒": "丰母", "枪": "木仓", "爆": "火暴", "炸": "火乍",
        "杀": "乂木", "药": "艹约",
    ]

    /// 是否开启零宽（读「输入设置 → 特殊字体」）
    static var enabled: Bool { IMESettingsStore.current.antiDetect }
    /// 是否开启拆字（读「输入设置 → 拆字」）
    static var radicalEnabled: Bool { IMESettingsStore.current.antiRadical }

    /// 敏感字拆字：命中映射表返回部首分解，否则返回原字符。
    static func radicalize(_ ch: Character) -> String {
        radicalMap[ch] ?? String(ch)
    }

    /// 整段加密：拆字（如开启）+ 零宽（如开启），两者可叠加。
    /// 换行 / 空格不处理（否则换行和分词被破坏）。
    static func apply(_ text: String) -> String {
        let useZW = enabled
        let useRadical = radicalEnabled
        guard (useZW || useRadical), !text.isEmpty else { return text }
        var out = ""
        for ch in text {
            if ch.isWhitespace {
                out.append(ch)
                continue
            }
            let piece = useRadical ? radicalize(ch) : String(ch)
            for pc in piece {
                out.append(pc)
                if useZW { out.append(zws.randomElement()!) }
            }
        }
        return out
    }

    /// 单字符加密（逐字上屏用）：拆字（如开启）+ 零宽（如开启）。
    static func applyCh(_ ch: String) -> String {
        let useZW = enabled
        let useRadical = radicalEnabled
        guard (useZW || useRadical), let c = ch.first, !c.isWhitespace else { return ch }
        var out = ""
        let piece = useRadical ? radicalize(c) : ch
        for pc in piece {
            out.append(pc)
            if useZW { out.append(zws.randomElement()!) }
        }
        return out
    }
}
