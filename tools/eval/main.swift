// 26 键拼音候选质量评测（CI 里跑，不依赖真机）
//
// 目的：把「候选栏垃圾不垃圾」变成一组可断言数字，改完代码 CI 直接判红/绿，
// 不再靠人肉试打字。
//
// 编译（在仓库根目录，macOS）：
//   xcrun swiftc -O -o /tmp/evalbin \
//     tools/eval/main.swift \
//     Sources/Keyboard/PinyinEngine.swift \
//     Sources/Shared/IMESettings.swift Sources/Shared/PhraseStore.swift \
//     Sources/Shared/SharedStore.swift Sources/Shared/SecVault.swift
// 运行（明文词库目录）：
//   ANRAN_DICT_DIR=Support/dict /tmp/evalbin
//
// 判定：全拼用例首位命中率 >= 88%、前三命中率 >= 96%，否则 exit(1)。

import Foundation

/// 全拼精确用例：输入 → 期望首候选
let fullCases: [(String, String)] = [
    ("nihao", "你好"), ("xiexie", "谢谢"), ("zaijian", "再见"),
    ("jintian", "今天"), ("mingtian", "明天"), ("tianqi", "天气"),
    ("shenme", "什么"), ("weishenme", "为什么"), ("zenme", "怎么"),
    ("keyi", "可以"), ("buzhidao", "不知道"), ("duibuqi", "对不起"),
    ("meiguanxi", "没关系"), ("women", "我们"), ("zhege", "这个"),
    ("shijian", "时间"), ("gongsi", "公司"), ("pengyou", "朋友"),
    ("dianhua", "电话"), ("chifan", "吃饭"), ("xihuan", "喜欢"),
    ("wanshang", "晚上"), ("xuexiao", "学校"), ("gongzuo", "工作"),
    ("wenti", "问题"), ("fangfa", "方法"), ("zhongguo", "中国"),
    ("xianzai", "现在"), ("yijing", "已经"), ("yinwei", "因为"),
    ("suoyi", "所以"), ("danshi", "但是"), ("ruguo", "如果"),
    ("keneng", "可能"), ("xuyao", "需要"), ("zhengzai", "正在"),
    ("mingbai", "明白"), ("zhidao", "知道"), ("kaixin", "开心"),
    ("shengri", "生日"), ("shouji", "手机"), ("youxi", "游戏"),
    ("yisheng", "医生"), ("laoban", "老板"), ("tongxue", "同学"),
]

/// 短输入用例（1~3 字母）：期望首位是最高频单字
let shortCases: [(String, String)] = [
    ("ni", "你"), ("wo", "我"), ("de", "的"), ("shi", "是"),
    ("bu", "不"), ("le", "了"), ("zai", "在"), ("you", "有"),
    ("hao", "好"), ("ta", "他"), ("ma", "吗"), ("ne", "呢"),
]

func topN(_ list: [PinyinCandidate], _ n: Int) -> [String] {
    list.prefix(n).map { $0.word }
}

func run(_ cases: [(String, String)], label: String,
         top1Threshold: Double, top3Threshold: Double) -> Bool {
    guard !cases.isEmpty else { return true }
    var hit1 = 0, hit3 = 0
    var failures: [String] = []

    for (py, want) in cases {
        // 逐条打印：万一引擎在某条输入上崩了，日志最后一行就是崩点
        print("· \(py)")
        fflush(stdout)
        let list = PinyinEngine.shared.candidates(for: py)
        let words = topN(list, 3)
        if words.first == want { hit1 += 1 }
        if words.contains(want) { hit3 += 1 } else {
            failures.append("\(py) 期望「\(want)」实际 \(words.prefix(3).joined(separator: " / "))")
        }
    }

    let n = Double(cases.count)
    let r1 = Double(hit1) / n, r3 = Double(hit3) / n
    print(String(format: "[%@] 用例 %d  首位 %.1f%%(%d)  前三 %.1f%%(%d)",
                 label, cases.count, r1 * 100, hit1, r3 * 100, hit3))
    if !failures.isEmpty {
        for f in failures.prefix(12) { print("    ✗ " + f) }
    }
    let ok = r1 >= top1Threshold && r3 >= top3Threshold
    print(ok ? "[\(label)] PASS" : "[\(label)] FAIL（阈值 首位>=\(Int(top1Threshold*100))% 前三>=\(Int(top3Threshold*100))%）")
    return ok
}

let okFull = run(fullCases, label: "全拼", top1Threshold: 0.88, top3Threshold: 0.96)
let okShort = run(shortCases, label: "短输入", top1Threshold: 0.70, top3Threshold: 0.90)
exit(okFull && okShort ? 0 : 1)
