// 26 键拼音候选质量评测（CI 里跑，不依赖真机）
//
// 目的：把「候选栏垃圾不垃圾」变成可断言数字，改完代码 CI 直接判红/绿，
// 不再靠人肉试打字。
//
// 四组用例 + 一个噪音指标：
//   ① 词库用例 cases.tsv（240 条，期望首位 = 该拼音下词库最高频词）
//      —— 抓「seed / 前缀补全 / 缩写表 / LM 罚分」把首位挤掉的回归
//   ② 短输入（1~3 字母）—— 抓最高频单字
//   ③ 长句（10~25 字母）—— 抓整句组句能力
//   ④ 错拼 —— 抓纠错召回
//   ⑤ 噪音：短输入时前 9 条里「≥5 字长候选」的占比上限
//
// 编译（仓库根目录，macOS）：
//   xcrun swiftc -Onone -g -o /tmp/evalbin \
//     tools/eval/main.swift tools/eval/stubs.swift \
//     Sources/Keyboard/PinyinEngine.swift \
//     Sources/Shared/SharedStore.swift Sources/Shared/SecVault.swift
// 运行：
//   ANRAN_DICT_DIR=Support/dict ANRAN_CASES=tools/eval/cases.tsv /tmp/evalbin

import Foundation

// ---------------------------------------------------------------- 用例

/// ① 词库用例（cases.tsv，期望 = 词库该键最高频词）
func loadCasesFile() -> [(String, String)] {
    let path = ProcessInfo.processInfo.environment["ANRAN_CASES"]
        ?? "tools/eval/cases.tsv"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("!! 读不到用例文件：\(path)")
        return []
    }
    var out: [(String, String)] = []
    for line in text.split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let p = line.split(separator: "\t")
        guard p.count >= 2 else { continue }
        out.append((String(p[0]), String(p[1])))
    }
    return out
}

/// ② 短输入：期望最高频单字
let shortCases: [(String, String)] = [
    ("ni", "你"), ("wo", "我"), ("de", "的"), ("shi", "是"),
    ("bu", "不"), ("le", "了"), ("zai", "在"), ("you", "有"),
    ("hao", "好"), ("ta", "他"), ("ma", "吗"), ("ne", "呢"),
]

/// ③ 长句：整句组句能力
let sentenceCases: [(String, String)] = [
    ("woxiangchifan", "我想吃饭"),
    ("jintiantianqihenhao", "今天天气很好"),
    ("womenmingtianjian", "我们明天见"),
    ("wanshangyiqichifan", "晚上一起吃饭"),
    ("xiexienidebangzhu", "谢谢你的帮助"),
    ("nizaiganma", "你在干嘛"),
    ("woyijingchiguole", "我已经吃过了"),
    ("zhegeshijianhenzhongyao", "这个事情很重要"),
    ("mingnianzaijian", "明年再见"),
    ("buhaoyisilaiwanle", "不好意思来晚了"),
    ("tamenchenglehaopengyou", "他们成了好朋友"),
    ("womenshizuihaodepengyou", "我们是最好的朋友"),
    ("jintianwanshangchishenme", "今天晚上吃什么"),
    ("nizuijinzenmeyang", "你最近怎么样"),
]

/// ④ 错拼：期望纠正后能进前三
let typoCases: [(String, String)] = [
    ("nihap", "你好"), ("jintain", "今天"), ("tainqi", "天气"),
    ("xieixe", "谢谢"), ("duibqi", "对不起"), ("meiguanx", "没关系"),
    ("zuotain", "昨天"), ("mingtain", "明天"), ("shenm", "什么"),
    ("wanshan", "晚上"),
]

// ---------------------------------------------------------------- 跑

struct Result {
    var total = 0
    var hit1 = 0
    var hit3 = 0
    var fails: [String] = []
}

func measure(_ cases: [(String, String)]) -> Result {
    var r = Result()
    for (py, want) in cases {
        let list = PinyinEngine.shared.candidates(for: py)
        let words = list.prefix(3).map { $0.word }
        r.total += 1
        if words.first == want { r.hit1 += 1 }
        if words.contains(want) { r.hit3 += 1 } else {
            r.fails.append("\(py) 期望「\(want)」实际 \(words.joined(separator: " / "))")
        }
    }
    return r
}

@discardableResult
func report(_ r: Result, _ label: String,
            top1: Double, top3: Double) -> Bool {
    guard r.total > 0 else { return true }
    let n = Double(r.total)
    let r1 = Double(r.hit1) / n, r3 = Double(r.hit3) / n
    print(String(format: "[%@] 用例 %d  首位 %.1f%%(%d)  前三 %.1f%%(%d)",
                 label, r.total, r1 * 100, r.hit1, r3 * 100, r.hit3))
    for f in r.fails.prefix(8) { print("    ✗ " + f) }
    let ok = r1 >= top1 && r3 >= top3
    print(ok ? "[\(label)] PASS"
             : "[\(label)] FAIL（阈值 首位>=\(Int(top1*100))% 前三>=\(Int(top3*100))%）")
    return ok
}

/// 噪音指标：短输入时前 9 条里「≥5 字的长候选」占比。
/// 商业输入法第一屏应该以词为主；长怪句占比高，用户就觉得「候选栏垃圾」。
func noiseShare() -> Double {
    var total = 0, long = 0
    let probes = ["nihao", "jintian", "shenme", "keyi", "xiexie",
                  "mingtian", "pengyou", "gongsi", "dianhua", "xihuan"]
    for py in probes {
        for c in PinyinEngine.shared.candidates(for: py).prefix(9) {
            total += 1
            if c.word.count >= 5 { long += 1 }
        }
    }
    return total == 0 ? 0 : Double(long) / Double(total)
}

let corpus = loadCasesFile()
print("词库用例：\(corpus.count) 条")

var allOK = true
allOK = report(measure(corpus), "词库", top1: 0.92, top3: 0.99) && allOK
allOK = report(measure(shortCases), "短输入", top1: 0.70, top3: 0.90) && allOK
allOK = report(measure(sentenceCases), "长句", top1: 0.60, top3: 0.85) && allOK
allOK = report(measure(typoCases), "错拼", top1: 0.30, top3: 0.80) && allOK

let noise = noiseShare()
print(String(format: "[噪音] 短输入前9条中 ≥5字长候选占比 %.1f%%（上限 20%%）", noise * 100))
if noise > 0.20 {
    print("[噪音] FAIL")
    allOK = false
} else {
    print("[噪音] PASS")
}

exit(allOK ? 0 : 1)
