// 26 键拼音候选质量 · 企业级评测（CI 里跑，不依赖真机）
//
// 把「候选栏好不好用」拆成四类可断言指标：
//   1. 质量：分类命中率（双字词 / 三字词 / 四字词 / 短输入 / 长句 / 错拼）
//   2. 性能：每次按键解码延迟 P50 / P95 / Max（冷启动单列）
//   3. 内存：进程峰值 RSS（词库是 mmap，超预算说明有意外堆分配）
//   4. 观感：短输入前 9 条里「≥5 字长候选」占比（长怪句不该占屏）
//
// 任何一项越界 → exit(1)，CI 直接红。改完代码不用人肉试打字。
//
// 编译（仓库根目录，macOS）：
//   xcrun swiftc -O -o /tmp/evalbin \
//     tools/eval/main.swift tools/eval/stubs.swift \
//     Sources/Keyboard/PinyinEngine.swift \
//     Sources/Shared/SharedStore.swift Sources/Shared/SecVault.swift
// 运行：
//   ANRAN_DICT_DIR=Support/dict ANRAN_CASES=tools/eval/cases.tsv /tmp/evalbin

import Foundation
import Darwin

// ---------------------------------------------------------------- 预算

enum Budget {
    static let wordTop1: Double = 0.92       // 双字词首位
    static let wordTop3: Double = 0.99
    static let shortTop1: Double = 0.70      // 短输入首位
    static let sentenceTop1: Double = 0.60   // 长句整句
    static let typoTop3: Double = 0.80       // 错拼进前三
    static let noiseShare: Double = 0.20     // 长候选占屏上限
    static let p95Ms: Double = 50            // 单键解码 P95
    static let maxMs: Double = 300           // 单键解码最坏
    static let coldStartMs: Double = 4000    // 首次（含解密/加载词库）
    static let peakRSSMB: Double = 260       // 峰值内存
}

// ---------------------------------------------------------------- 用例

struct Case { let py: String; let want: String; let cat: String }

func loadCasesFile() -> [Case] {
    let env = ProcessInfo.processInfo.environment["ANRAN_CASES"]
    // 多个候选路径：CI 里 cwd 可能是仓库根，也可能被 lldb 改掉
    let paths = [env, "tools/eval/cases.tsv",
                 "../tools/eval/cases.tsv", "../../tools/eval/cases.tsv"]
        .compactMap { $0 }
    var text: String?
    var used = ""
    for p in paths {
        if let t = try? String(contentsOfFile: p, encoding: .utf8) {
            text = t; used = p; break
        }
    }
    guard let body = text else {
        print("!! 读不到用例文件。尝试过：\(paths)")
        print("   cwd=\(FileManager.default.currentDirectoryPath)")
        return []
    }
    print("用例文件：\(used)")
    var out: [Case] = []
    for line in body.split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let p = line.split(separator: "\t")
        guard p.count >= 2 else { continue }
        out.append(Case(py: String(p[0]), want: String(p[1]),
                        cat: p.count >= 3 ? String(p[2]) : "w2"))
    }
    return out
}

let shortCases: [(String, String)] = [
    ("ni", "你"), ("wo", "我"), ("de", "的"), ("shi", "是"),
    ("bu", "不"), ("le", "了"), ("zai", "在"), ("you", "有"),
    ("hao", "好"), ("ta", "他"), ("ma", "吗"), ("ne", "呢"),
]

let sentenceCases: [(String, String)] = [
    ("woxiangchifan", "我想吃饭"),
    ("jintiantianqihenhao", "今天天气很好"),
    ("womenmingtianjian", "我们明天见"),
    ("wanshangyiqichifan", "晚上一起吃饭"),
    ("xiexienidebangzhu", "谢谢你的帮助"),
    ("nizaiganma", "你在干嘛"),
    ("woyijingchiguole", "我已经吃过了"),
    ("zhegeshiqinghenzhongyao", "这个事情很重要"),
    ("mingnianzaijian", "明年再见"),
    ("buhaoyisilaiwanle", "不好意思来晚了"),
    ("tamenchenglehaopengyou", "他们成了好朋友"),
    ("womenshizuihaodepengyou", "我们是最好的朋友"),
    ("jintianwanshangchishenme", "今天晚上吃什么"),
    ("nizuijinzenmeyang", "你最近怎么样"),
]

let typoCases: [(String, String)] = [
    ("nihap", "你好"), ("jintain", "今天"), ("tainqi", "天气"),
    ("xieixe", "谢谢"), ("duibqi", "对不起"), ("meiguanx", "没关系"),
    ("zuotain", "昨天"), ("mingtain", "明天"), ("shenm", "什么"),
    ("wanshan", "晚上"),
]

// ---------------------------------------------------------------- 工具

struct Result {
    var total = 0
    var hit1 = 0
    var hit3 = 0
    var fails: [String] = []
    var t0 = 0.0
    var t95 = 0.0
    var tMax = 0.0
}

func measure(_ cases: [(String, String)]) -> Result {
    var r = Result()
    var times: [Double] = []
    for (py, want) in cases {
        let t = CFAbsoluteTimeGetCurrent()
        let list = PinyinEngine.shared.candidates(for: py)
        times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        let words = list.prefix(3).map { $0.word }
        r.total += 1
        if words.first == want { r.hit1 += 1 }
        if words.contains(want) { r.hit3 += 1 } else {
            r.fails.append("\(py) 期望「\(want)」实际 \(words.joined(separator: " / "))")
        }
    }
    times.sort()
    if !times.isEmpty {
        r.t0 = times[times.count / 2]
        r.t95 = times[min(times.count - 1, Int(Double(times.count) * 0.95))]
        r.tMax = times.last ?? 0
    }
    return r
}

var ok = true

@discardableResult
func check(_ r: Result, _ label: String,
           top1: Double, top3: Double) -> Bool {
    guard r.total > 0 else { return true }
    let n = Double(r.total)
    let r1 = Double(r.hit1) / n, r3 = Double(r.hit3) / n
    print(String(format: "[%@] n=%d  首位 %.1f%%  前三 %.1f%%  解码 P50 %.1fms P95 %.1fms max %.1fms",
                 label, r.total, r1 * 100, r3 * 100, r.t0, r.t95, r.tMax))
    for f in r.fails.prefix(6) { print("    ✗ " + f) }
    let pass = r1 >= top1 && r3 >= top3
    print(pass ? "[\(label)] PASS" : "[\(label)] FAIL（阈值 首位≥\(Int(top1*100))% 前三≥\(Int(top3*100))%）")
    return pass
}

/// 峰值 RSS（macOS 上 ru_maxrss 单位是字节）
func peakRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / (1024 * 1024)
}

// ---------------------------------------------------------------- 跑

let corpus = loadCasesFile()
print("词库用例：\(corpus.count) 条（\(Set(corpus.map { $0.cat }).sorted().joined(separator: "/"))）")

// 冷启动：第一条会把词库解密 + mmap + 音节表建起来
let cold0 = CFAbsoluteTimeGetCurrent()
_ = PinyinEngine.shared.candidates(for: "ceshi")
let coldMs = (CFAbsoluteTimeGetCurrent() - cold0) * 1000
print(String(format: "[冷启动] 首次解码（含词库加载）%.1fms（预算 %.0fms）", coldMs, Budget.coldStartMs))
if coldMs > Budget.coldStartMs { ok = false; print("[冷启动] FAIL") }

// 分类跑（每类单独计时，便于定位是哪一类退化）
for cat in ["w2", "w3", "w4"] {
    let sub = corpus.filter { $0.cat == cat }.map { ($0.py, $0.want) }
    if sub.isEmpty { continue }
    if !check(measure(sub), cat, top1: Budget.wordTop1, top3: Budget.wordTop3) { ok = false }
}
if !check(measure(shortCases), "短输入", top1: Budget.shortTop1, top3: 0.90) { ok = false }
if !check(measure(sentenceCases), "长句", top1: Budget.sentenceTop1, top3: 0.85) { ok = false }
if !check(measure(typoCases), "错拼", top1: 0.30, top3: Budget.typoTop3) { ok = false }

// 性能总账：拿全量词库用例的延迟分布
let perf = measure(corpus.map { ($0.py, $0.want) })
print(String(format: "[性能] 240 键解码 P50 %.1fms  P95 %.1fms  max %.1fms（预算 P95 %.0f / max %.0f）",
             perf.t0, perf.t95, perf.tMax, Budget.p95Ms, Budget.maxMs))
if perf.t95 > Budget.p95Ms || perf.tMax > Budget.maxMs {
    print("[性能] FAIL")
    ok = false
} else {
    print("[性能] PASS")
}

// 噪音：短输入前 9 条里长候选占比
var totalSlots = 0, longSlots = 0
for py in ["nihao", "jintian", "shenme", "keyi", "xiexie",
           "mingtian", "pengyou", "gongsi", "dianhua", "xihuan"] {
    for c in PinyinEngine.shared.candidates(for: py).prefix(9) {
        totalSlots += 1
        if c.word.count >= 5 { longSlots += 1 }
    }
}
let noise = totalSlots == 0 ? 0 : Double(longSlots) / Double(totalSlots)
print(String(format: "[噪音] 短输入前9条中 ≥5字长候选 %.1f%%（上限 %.0f%%）",
             noise * 100, Budget.noiseShare * 100))
if noise > Budget.noiseShare { print("[噪音] FAIL"); ok = false }
else { print("[噪音] PASS") }

let rss = peakRSSMB()
print(String(format: "[内存] 峰值 RSS %.1fMB（预算 %.0fMB）", rss, Budget.peakRSSMB))
if rss > Budget.peakRSSMB { print("[内存] FAIL"); ok = false }
else { print("[内存] PASS") }

print(ok ? "==== 全部指标达标 ====" : "==== 有指标未达标 ====")
exit(ok ? 0 : 1)
