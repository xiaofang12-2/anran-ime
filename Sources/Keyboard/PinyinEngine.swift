import Foundation

/// 一条候选词
struct PinyinCandidate: Equatable {
    let word: String
    let score: Int
    /// 这条候选吃掉了输入串里多少个字符（用来做「部分上屏」：
    /// 打「jintianx」选出「今天」后，剩下的「x」继续留在拼音串里接着拼）
    let consumed: Int
    /// 是不是「原样英文」候选（中英混输时把拼音串本身也能直接上屏）
    let literal: Bool
    /// 来自 librime 的第几条候选（选中时要回灌给它学词）；自研层为 nil
    let rimeIndex: Int?
    /// 强优先候选：自研缩写表命中的策展词（口语/梗/怼人），或用户自己记下的词。
    /// 合并时顶到 librime 前面
    let isPriority: Bool

    init(word: String, score: Int, consumed: Int = 0, literal: Bool = false,
         rimeIndex: Int? = nil, isPriority: Bool = false) {
        self.word = word
        self.score = score
        self.consumed = consumed
        self.literal = literal
        self.rimeIndex = rimeIndex
        self.isPriority = isPriority
    }
}

/// 本地拼音引擎
///
/// 词库 `Support/dict/pinyin.bin`（72 万词条）用 `mappedIfSafe` 内存映射，
/// 不整块读进堆 —— 键盘扩展只有 30~60MB 内存，这是硬约束。
/// 语言模型 `Support/dict/assoc.bin` 是字级 bigram（上下文首字 -> 后继字），
/// 体积很小，启动一次性读进字典。
///
/// 解码路子对标 librime / 百度输入法（见 librime `gear/poet.cc`、`gear/grammar.h`）：
///   输入拼音
///     -> 音节图 SyllableGraph：每个位置能切出哪些音节
///     -> 词图 WordGraph：音节路径拼成拼音串去词典查词
///     -> 词图上的 Beam Search：score = Σ entry_weight(词) + Σ context_penalty(词 | 前文)
///        entry_weight 即词典里的 log P(词)；context_penalty 由字级 bigram 给出，
///        这就是 `grammar.h` 的 Grammar::Evaluate()。
///     -> 候选 = 全覆盖句子 + 前缀补全词
///
/// 词典里每条候选存的是「全局对数概率」两字节，不是名次。
/// 所以跨键比较、句子路径打分用的是同一把尺子 —— 不再有 900000/620000 这类手写常数。
final class PinyinEngine {

    static let shared = PinyinEngine()

    private var data: Data?
    private var entryCount = 0
    private var keyOffTable = 0
    private var valOffTable = 0

    private var syllableSet = Set<String>()

    // MARK: 百度 cell 词库（seed.bin）
    //
    // 从百度输入法 APK 的 assets/ipt/{0,1,2}.bcd 解析出的 10,736 条内置词条
    // （口语片段 / 成语 / 软件功能名），单独做成一个小词库 cell，与主词库同格式。
    // 这些是**成句的口语片段**（"我也不知道啊"），主词库（词为单位）里没有，
    // 正是长口语句子候选缺的那一块。mmap 读取，390KB，不占堆。
    private var seedData: Data?
    private var seedCount = 0
    private var seedKeyTbl = 0
    private var seedValTbl = 0

    /// 字级 bigram 语言模型：上下文首字 -> {后继字: log P(后继 | 上下文)}。
    /// 词图打分的「上下文项」（对标 librime grammar.h 的 Grammar::Evaluate）。
    private var lm: [String: [String: Double]] = [:]

    /// 词级 n-gram 语言模型（ANWG v2，mmap 紧凑二进制）：
    /// 前词 -> {后继词: log P(后继 | 前词)}。内存映射读取，不整块进堆 ——
    /// 键盘扩展内存红线是硬约束（rime-ice 全套词库已是大头）。
    /// 词图打分的「上下文项」升级版：直接建模 词→词 接续（今天→天气），
    /// 比字级 bigram 准得多。数据来自 rime-ice 短语词典 + 策展表，离线训练；
    /// 缺失时表为空，打分自动退回字级 bigram，不破坏现有引擎。
    private var wlmData: Data?
    private var wlmCount = 0
    private var wlmKeyTbl = 0
    private var wlmValTbl = 0

    /// 词级 LM 的「后继集合」解析缓存：把 blob 一次性解析成字典。
    /// 原来每次 wordPenalty 都要 split + 逐条 UTF-8 解码（每次至少 1 次堆分配），
    /// 而 beam 内层是 O(状态 × 边) 次调用 —— 这就是宽度只能压到 6~8 的根本原因。
    /// 变成 O(1) 查表后，beam 才敢放宽度换精度。
    private var wlmMemo: [String: [String: Double]] = [:]
    private var wlmMemoQ: [String] = []
    private static let wlmMemoMax = 1024
    private var wlmKeyBlk = 0
    private var wlmValBlk = 0

    // ---- 三元语言模型（ANWT v1）：词 a,b -> 词 c ----
    // 二元分不出「一下→在 / 一下→再」这种：两项都未登录、罚分相同，
    // 只能由 unigram 决胜（在 比 再 常见得多）。三元能看到「查/一下/再」才判得准。
    private var tlmData: Data?
    private var tlmCount = 0
    private var tlmKeyTbl = 0
    private var tlmValTbl = 0
    private var tlmMemo: [String: [String: Double]] = [:]
    private var tlmMemoQ: [String] = []
    private static let tlmMemoMax = 512

    /// 自定义短语：触发码 -> 展开文本 + 命中后落位（主程序下发，见 PhraseStore）
    private var phrases: [(code: String, text: String, position: Int)] = []

    private var ready = false

    /// 上一次全量解码耗时（毫秒）。性能调度用：键盘扩展是 30~60MB 内存 +
    /// 秒出候选的硬约束，超时的解码路径要在设置里能看见（诊断页显示）。
    private(set) var lastDecodeMs = 0.0

    private var cacheKey = ""
    private var cacheResult: [PinyinCandidate] = []

    /// 小 LRU：最近 8 个输入串的候选。
    /// 单槽缓存时，按一次退格就是「整个词图重算一遍」——长按连删每秒 20 多次，
    /// 扩展的 CPU 预算扛不住（被系统杀掉的表现同样是「键盘突然消失」）。
    /// 8 条足够覆盖「打错一个字母再退回来」这类高频回退。
    private var lruCache: [String: [PinyinCandidate]] = [:]
    private var lruOrder: [String] = []
    private static let lruCap = 8

    // 用户词频（越用越准）
    private var userFreq: [String: Int] = [:]
    /// 用户自己记下的「拼音 -> 词」，打同样拼音时它们永远排在词典前面
    private var userWords: [String: [String]] = [:]
    /// 用户词级 bigram：上一个词 -> {当前词: 次数}。
    /// 上屏时由 InputEngine 回灌（「今天」之后你常打「天气」），
    /// 让上屏联想越用越贴你的习惯 —— 纯本地，不出设备。
    private var userBigram: [String: [String: Int]] = [:]
    private let userQueue = DispatchQueue(label: "anran.ime.userfreq")

    private struct UserData: Codable {
        var freq: [String: Int]
        var words: [String: [String]]
        /// 旧存档没有这一项，用可选保证向后兼容
        var bigram: [String: [String: Int]]?
    }

    // MARK: - 对数概率编码（与 build_dict.py 一一对应）

    private static let logBase = 0x10
    private static let logSpan = 0x7E - 0x10 + 1        // 111
    private static let logN = logSpan * logSpan         // 12321
    private static let logFloor = 24.0

    // 语言模型量化参数（与 build_assoc.py 一一对应）
    private static let lmFloor = -12.0
    private static let lmRef = -3.5
    private static let lmWeight = 0.6        // 字级 bigram 权重（在/再、着/这 靠它）

    // 词级 LM 量化参数（与 build_assoc_w.py 一一对应）
    private static let wlmFloor = -10.0
    private static let wlmRef = -3.0
    private static let wlmWeight = 0.8       // 词级 bigram 权重（真实搭配靠它）
    private static let wlmPenCap = 3.0       // 单次接续罚分上限
    private static let tlmFloor = -8.0       // 三元 log P 下限（与 assoc_t.bin 的 LPMIN 一致）
    private static let tlmRef = -3.0
    private static let tlmWeight = 0.9       // 三元信息量更大，权重略高于二元
    private static let tlmPenCap = 3.0
    private static let tlmBackoff = 0.35     // 回退二元的代价
    private static let lmPenCap = 2.5        // 单次字接续罚分上限

    /// 终极兜底：任何字母串都必须出汉字，绝不让面板只剩英文。
    /// 音节起头的 u / i / ü 的规范写法 —— 词库里没有 u/i/v 开头的拼音键，
    /// 乌=wu、一=yi、鱼=yu，乱按到这几个字母时按规范拼写再查一次。
    private static let leadMap: [Character: String] = ["u": "wu", "i": "yi", "v": "yu"]
    /// 兜底候选的罚分系数：罚 fbPen×被砍掉的长度，保证它永远排在正常候选后面
    private static let fbPen = 3.0

    /// 缩写/混拼候选的罚分：整串切不成音节时缩写只是「猜」，
    /// 只要存在「真音节读出来的词」（含末音节补全），真读法必须压过猜的。
    /// 打 zad 时 za+di 读出的「咋的」要压过 zd 缩写出的「知道」。
    private static let abbrPen = 3.2
    /// 末音节补全的罚分：每补一个字母罚一点，保证补全候选排在「本来就完整」的候选后面
    private static let tailPen = 1.0
    /// 末音节补全最多展开多少个候选音节
    private static let tailMax = 40
    /// 词数罚分：同样概率下「少切、长词」更贴近真实意图（你好 优于 你 好）。
    /// 0.5 → 0.7：多段拼句在长输入时仍然该有（整句候选），但不该轻易压过整词。
    private static let wordPen = 0.7

    private func decodeLogp(_ a: Character, _ b: Character) -> Double {
        let hi = Int(a.unicodeScalars.first?.value ?? 0) - PinyinEngine.logBase
        let lo = Int(b.unicodeScalars.first?.value ?? 0) - PinyinEngine.logBase
        var q = hi * PinyinEngine.logSpan + lo
        if q < 0 { q = 0 }
        if q > PinyinEngine.logN - 1 { q = PinyinEngine.logN - 1 }
        return Double(q) / Double(PinyinEngine.logN - 1) * PinyinEngine.logFloor
            - PinyinEngine.logFloor
    }

    private init() {
        loadUser()
    }

    // MARK: - 诊断（仅 CI 评测用）

    /// 设了 `ANRAN_TRACE=1` 才输出，正常运行零开销。
    /// 用途：命令行评测里崩了要能精确到函数（lldb 的 backtrace 在这种环境里拿不全）。
    private static let tracing = ProcessInfo.processInfo.environment["ANRAN_TRACE"] != nil

    private func tr(_ s: @autoclosure () -> String) {
        guard PinyinEngine.tracing else { return }
        FileHandle.standardError.write(Data(("[T] " + s() + "\n").utf8))
    }

    // MARK: - 词库加载
    //
    // 分成两档，这是「按键就跳走」的核心修复：
    //   · ensureMeta  —— 小层（assoc 745KB / assoc_w 6MB / seed 390KB），随时可加载
    //   · ensureDict  —— 主词库 27MB，只允许尝试一次
    //
    // 旧实现把两者绑在一起：只要 librime 没就绪，每次敲键都会重新 stage 一遍
    // 27MB 词库；而且 librime 已经占了 50MB 时再去解 27MB，
    // 峰值直接顶穿扩展的 jetsam 红线 —— 表现就是「打几个字键盘消失、切回上一个输入法」。
    private var metaLoaded = false
    private var dictTried = false

    private func ensureMeta() {
        if metaLoaded { return }
        metaLoaded = true

        tr("meta: stage assoc")
        let assocStaged = SecVault.stage("assoc", ext: "bin")
        if let url = assocStaged {
            loadAssoc(url)
        }
        SecVault.dispose(assocStaged)

        // 词级 n-gram（升级版上下文项）：缺失不影响，打分退回字级 bigram
        tr("meta: stage assoc_w")
        let wStaged = SecVault.stage("assoc_w", ext: "bin")
        if let url = wStaged {
            loadAssocW(url)
        }
        SecVault.dispose(wStaged)

        // 三元语言模型：缺了自动退回二元，不影响主链路
        let tStaged = SecVault.stage("assoc_t", ext: "bin")
        if let url = tStaged {
            loadTrigram(url)
        }
        SecVault.dispose(tStaged)

        // 百度内置词条 cell（口语片段/成语/软件名）：缺了不影响主链路
        tr("meta: stage seed")
        let seedStaged = SecVault.stage("seed", ext: "bin")
        if let url = seedStaged {
            loadSeed(url)
        }
        SecVault.dispose(seedStaged)
    }

    /// 主词库：只在真的要用自研解码时才加载，且**只试一次**。
    /// 失败不重试 —— 重试的代价是每次按键再解一遍 27MB。
    @discardableResult
    private func ensureDict() -> Bool {
        if ready { return true }
        if dictTried { return false }
        dictTried = true

        // 词库在包里是密文（SecVault）：流式解到临时文件 -> 内存映射 -> 立刻删盘
        tr("dict: stage pinyin")
        let staged = SecVault.stage("pinyin", ext: "bin")
        if let url = staged,
           let d = try? Data(contentsOf: url, options: .mappedIfSafe),
           d.count > 44, d.prefix(4) == Data("ANPY".utf8) {
            data = d
            entryCount = u32(8)
            keyOffTable = u32(12)
            valOffTable = u32(16)
            tr("dict: mmap ok, entries=\(entryCount)")
            loadSyllables()
            tr("dict: syllables=\(syllableSet.count)")
            ready = true
            clearCache()
        }
        SecVault.dispose(staged)
        return ready
    }

    /// 内存告急/长时间空闲：把主词库映射放掉（下次需要时再加载一次）。
    /// 只有 ready 才需要，且必须同时清 dictTried 才能重新加载。
    func releaseDict() {
        data = nil
        entryCount = 0
        keyOffTable = 0
        valOffTable = 0
        syllableSet = []
        ready = false
        dictTried = false
        clearCache()
        cacheResult = []
    }

    /// 读 seed cell：与主词库同格式（ANPY v2），只取 key/val 偏移表，mmap 不复制。
    private func loadSeed(_ url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe),
              d.count > 44, d.prefix(4) == Data("ANPY".utf8) else { return }
        seedData = d
        seedCount = u32from(d, 8)
        seedKeyTbl = u32from(d, 12)
        seedValTbl = u32from(d, 16)
        if seedCount <= 0 || seedCount > 400_000 { seedData = nil; seedCount = 0 }
    }

    private func seedString(_ a: Int, _ b: Int) -> String {
        guard let d = seedData, a >= 0, b >= a, b <= d.count else { return "" }
        return String(decoding: d[a..<b], as: UTF8.self)
    }

    /// 整串精确命中 seed cell 的候选（二分）。
    /// 只做精确匹配：这些是整句口语片段/成语/软件名，前缀召回没有意义。
    private func seedCandidates(_ key: String) -> [(word: String, logp: Double)] {
        guard let d = seedData, seedCount > 0 else { return [] }
        var lo = 0, hi = seedCount
        while lo < hi {
            let mid = (lo + hi) / 2
            let k = seedString(u32from(d, seedKeyTbl + 4 * mid),
                               u32from(d, seedKeyTbl + 4 * (mid + 1)))
            if k < key { lo = mid + 1 } else { hi = mid }
        }
        guard lo < seedCount else { return [] }
        let a = u32from(d, seedKeyTbl + 4 * lo)
        let b = u32from(d, seedKeyTbl + 4 * (lo + 1))
        if seedString(a, b) != key { return [] }
        let va = u32from(d, seedValTbl + 4 * lo)
        let vb = u32from(d, seedValTbl + 4 * (lo + 1))
        let blob = seedString(va, vb)
        var out: [(String, Double)] = []
        for rec in blob.split(separator: "\u{01}", omittingEmptySubsequences: true) {
            let arr = Array(rec)
            if arr.count < 3 { continue }
            out.append((String(arr[2...]), decodeLogp(arr[0], arr[1])))
        }
        return out
    }

    private func loadSyllables() {
        let sylCount = u32(28)
        let sylOffTable = u32(32)
        guard sylCount > 0 && sylCount < 20000 else { return }
        var set = Set<String>()
        set.reserveCapacity(sylCount)
        for i in 0..<sylCount {
            let s = string(u32(sylOffTable + 4 * i), u32(sylOffTable + 4 * (i + 1)))
            if !s.isEmpty { set.insert(s) }
        }
        syllableSet = set
    }

    private func loadAssoc(_ url: URL) {
        // ANBG v2：magic(4) + 版本(1) + payload。
        // payload = record 用 \u{03} 分隔；record = 首字 + \u{02} + entry 用 \u{01} 分隔；
        // entry = 后继字 + \u{04} + 概率字节。
        guard let d = try? Data(contentsOf: url), d.count > 5 else { return }
        let text = String(decoding: d.dropFirst(5), as: UTF8.self)
        var map = [String: [String: Double]]()
        for rec in text.split(separator: "\u{03}") {
            guard let sep = rec.firstIndex(of: "\u{02}") else { continue }
            let ctx = String(rec[rec.startIndex..<sep])
            guard !ctx.isEmpty else { continue }
            let rest = rec[rec.index(after: sep)...]
            var row = [String: Double]()
            for ent in rest.split(separator: "\u{01}") {
                let a = Array(ent)
                if a.count < 2 { continue }
                let code = Int(a[a.count - 1].unicodeScalars.first?.value ?? 0)
                let lp = PinyinEngine.lmFloor
                    + (Double(code) - 2) / 253.0 * (0 - PinyinEngine.lmFloor)
                row[String(a[0..<(a.count - 1)])] = lp
            }
            if !row.isEmpty { map[ctx] = row }
        }
        lm = map
    }

    /// 载词级 n-gram（ANWG v2 紧凑 mmap 格式）：magic(4) + 版本(1) + entryCount(4)
    /// + keyOffTblPos(4) + valOffTblPos(4) + keyBlkPos(4) + valBlkPos(4)，
    /// 之后是 key 偏移表 / val 偏移表 / key 块 / val 块。与 build_assoc_w.py 一一对应。
    /// 只解析头并记下偏移，查询时按需切片（内存映射，零堆膨胀）。
    private func loadTrigram(_ url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 25 else { return }
        guard d.prefix(4) == Data("ANWT".utf8), d[4] == 0x31 /* '1' */ else { return }
        tlmData = d
        tlmCount = u32from(d, 5)
        tlmKeyTbl = u32from(d, 9)
        tlmValTbl = u32from(d, 13)
    }

    private func loadAssocW(_ url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 25 else { return }
        guard d.prefix(4) == Data("ANWG".utf8), d[4] == 0x32 /* '2' */ else { return }
        wlmData = d
        wlmCount = u32from(d, 5)
        wlmKeyTbl = u32from(d, 9)
        wlmValTbl = u32from(d, 13)
        wlmKeyBlk = u32from(d, 17)
        wlmValBlk = u32from(d, 21)
    }

    /// 任意 Data 上的小端 u32 读取（用于词级 LM 偏移表）
    private func u32from(_ d: Data, _ off: Int) -> Int {
        guard off >= 0, off + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { raw -> Int in
            let b = raw.bindMemory(to: UInt8.self)
            return Int(b[off]) | (Int(b[off + 1]) << 8)
                | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)
        }
    }

    private func wlmKeyAt(_ i: Int) -> String {
        wlmString(u32from(wlmData!, wlmKeyTbl + 4 * i),
                  u32from(wlmData!, wlmKeyTbl + 4 * (i + 1)))
    }

    private func wlmString(_ a: Int, _ b: Int) -> String {
        guard let d = wlmData, a >= 0, b > a, b <= d.count else { return "" }
        return String(decoding: d[a..<b], as: UTF8.self)
    }

    /// 二分定位前词，返回它的后继 blob（原始字节：
    /// 每条 = [概率字节 1 字节][后继词 UTF8]，以 0x01 分隔）。
    /// 走字节层解析，避免把概率字节当 UTF-8 解码（>=0x80 会被替换成 U+FFFD 而失真）。
    private func wlmValBlob(for prev: String) -> Data? {
        guard let d = wlmData, wlmCount > 0 else { return nil }
        var lo = 0, hi = wlmCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if wlmKeyAt(mid) < prev { lo = mid + 1 } else { hi = mid }
        }
        if lo < wlmCount, wlmKeyAt(lo) == prev {
            let a = u32from(d, wlmValTbl + 4 * lo)
            let b = u32from(d, wlmValTbl + 4 * (lo + 1))
            guard a >= 0, b > a, b <= d.count else { return nil }
            // 返回切片而不是 subdata：subdata 会复制（每次查询最多几 KB，
            // 但按键是热路径，能省就省）。切片的下标是绝对下标，
            // wlmParseEntry 已按 first/dropFirst 处理。
            return d[a..<b]
        }
        return nil
    }

    /// 解析单条后继 entry：[概率字节][后继词 UTF8] -> (词, 条件对数概率)
    ///
    /// ⚠️ 必须用 first/dropFirst，**不能用 seg[0]**：`split` 出来的每个元素是
    /// 原 Data 的**切片**，startIndex 不是 0（第二条起就大于 0），
    /// 用绝对下标会直接越界崩溃 —— 表现为「打着打着键盘消失、切回上一输入法」。
    private func wlmParseEntry(_ seg: Data) -> (String, Double)? {
        guard seg.count >= 2, let first = seg.first else { return nil }
        let code = Int(first)
        let word = String(decoding: seg.dropFirst(), as: UTF8.self)
        guard !word.isEmpty else { return nil }
        let lp = PinyinEngine.wlmFloor
            + (Double(code) - 2) / 253.0 * (0 - PinyinEngine.wlmFloor)
        return (word, lp)
    }

    /// 取 (前词, 后继词) 的条件对数概率；前词不在表里返回 nil（调用方退回字级 bigram），
    /// 前词在表但后继词不在其后继集合里返回 wlmFloor（最不常见接续）。
    private func wlmLP(_ prev: String, _ fol: String) -> Double? {
        if let m = wlmMemo[prev] { return m[fol] ?? PinyinEngine.wlmFloor }
        guard let blob = wlmValBlob(for: prev) else { return nil }
        var m: [String: Double] = [:]
        m.reserveCapacity(16)
        for seg in blob.split(separator: 0x01) {
            if let (w, lp) = wlmParseEntry(seg) { m[w] = lp }
        }
        memoizeSuccessors(prev, m)
        return m[fol] ?? PinyinEngine.wlmFloor
    }

    /// FIFO 淘汰（不做真 LRU：这里命中率对顺序不敏感，省一次链表维护）
    private func memoizeSuccessors(_ prev: String, _ m: [String: Double]) {
        if wlmMemoQ.count >= PinyinEngine.wlmMemoMax {
            let drop = wlmMemoQ.count / 2
            for i in 0..<drop { wlmMemo.removeValue(forKey: wlmMemoQ[i]) }
            wlmMemoQ.removeFirst(drop)
        }
        wlmMemo[prev] = m
        wlmMemoQ.append(prev)
    }

    /// 词级上下文项：前词 -> 后继词。命中返回罚分（>=0），没见过的接续（前词不在表）
    /// 返回 nil（调用方退回字级 bigram）。常见接续返回 0；生僻接续按最罕见罚。
    /// 比字级 bigram 更贴合真实搭配 ——「今天→天气」而不是「今→天→气」。
    private func wordPenalty(_ prev: String, _ fol: String) -> Double? {
        guard let p = wlmLP(prev, fol) else { return nil }
        if p >= PinyinEngine.wlmRef { return 0 }
        // 封顶：LM 里没有的搭配只说明「没见过」，不等于错。
        // 不封顶的话任何见过的搭配都能碾压更好的词（打 kendinghui 会为了
        // 「肯定→会」而牺牲更合理的切分）。
        return min(PinyinEngine.wlmWeight * (PinyinEngine.wlmRef - p),
                   PinyinEngine.wlmPenCap)
    }

    /// 用户自己的接续习惯：常这么打就给负罚分（等价加分）。
    /// 商业输入法的「按你的用词习惯排序」必须作用在 beam 内部 ——
    /// 只在最后重排的话，你的习惯切分早在剪枝阶段就被丢掉了。
    private func userPenalty(_ prev: String, _ fol: String) -> Double {
        guard let m = userBigram[prev], let c = m[fol], c > 0 else { return 0 }
        return -min(Double(c), 8.0) * 0.45
    }

    /// 三元查询：(a,b) 之后接 c 的条件对数概率。
    /// 键存在但 c 不在其后继里 → 返回三元下限（表示「这组搭配没见过」）；
    /// 键本身不存在 → nil（调用方回退二元）。
    private func trigramLP(_ a: String, _ b: String, _ c: String) -> Double? {
        let key = a + "\u{1f}" + b
        if let m = tlmMemo[key] { return m[c] ?? PinyinEngine.tlmFloor }
        guard let d = tlmData, tlmCount > 0 else { return nil }
        var lo = 0, hi = tlmCount
        while lo < hi {
            let mid = (lo + hi) / 2
            let ka = u32from(d, tlmKeyTbl + 4 * mid)
            let kb = u32from(d, tlmKeyTbl + 4 * (mid + 1))
            let k = String(decoding: d[ka..<kb], as: UTF8.self)
            if k < key { lo = mid + 1 } else { hi = mid }
        }
        guard lo < tlmCount else { return nil }
        let ka = u32from(d, tlmKeyTbl + 4 * lo)
        let kb = u32from(d, tlmKeyTbl + 4 * (lo + 1))
        guard String(decoding: d[ka..<kb], as: UTF8.self) == key else { return nil }

        let va = u32from(d, tlmValTbl + 4 * lo)
        let vb = u32from(d, tlmValTbl + 4 * (lo + 1))
        var row: [String: Double] = [:]
        row.reserveCapacity(8)
        for seg in d[va..<vb].split(separator: 0x01) {
            guard let first = seg.first else { continue }
            let w = String(decoding: seg.dropFirst(), as: UTF8.self)
            if w.isEmpty { continue }
            row[w] = PinyinEngine.tlmFloor
                + (Double(first) - 2) / 253.0 * (0 - PinyinEngine.tlmFloor)
        }
        // 与二元同一套 FIFO 淘汰
        if tlmMemoQ.count >= PinyinEngine.tlmMemoMax {
            let drop = tlmMemoQ.count / 2
            for i in 0..<drop { tlmMemo.removeValue(forKey: tlmMemoQ[i]) }
            tlmMemoQ.removeFirst(drop)
        }
        tlmMemo[key] = row
        tlmMemoQ.append(key)
        return row[c] ?? PinyinEngine.tlmFloor
    }

    /// 三元罚分：命中用三元，键不存在回退二元并加一点回退罚分
    /// （让「统计过」的三元搭配压过「没统计过」的，但不至于把二元信息丢掉）。
    private func trigramPenalty(_ a: String, _ b: String, _ c: String) -> Double? {
        if let lp = trigramLP(a, b, c) {
            if lp >= PinyinEngine.tlmRef { return 0 }
            return min(PinyinEngine.tlmWeight * (PinyinEngine.tlmRef - lp),
                       PinyinEngine.tlmPenCap)
        }
        guard let bp = wordPenalty(b, c) else {
            guard let lc = b.last, let fc = c.first else { return nil }
            return lmPenalty(lc, fc) + PinyinEngine.tlmBackoff
        }
        return bp + PinyinEngine.tlmBackoff
    }

    /// 词级接续亲和度：prev 之后接 fol 在词级 LM 里算不算常见接续（0/1）。
    /// internal：InputEngine.contextBoost 跨文件调用。
    func wordAffinity(_ prev: String, _ fol: String) -> Double {
        guard let p = wlmLP(prev, fol) else { return 0 }
        return p >= PinyinEngine.wlmRef ? 1.0 : 0.0
    }

    /// 上屏联想用：返回前词的所有后继词（按概率降序）。
    private func wlmSuccessors(_ prev: String) -> [(String, Double)] {
        var m = wlmMemo[prev]
        if m == nil {
            guard let blob = wlmValBlob(for: prev) else { return [] }
            var built: [String: Double] = [:]
            built.reserveCapacity(16)
            for seg in blob.split(separator: 0x01) {
                if let (w, lp) = wlmParseEntry(seg) { built[w] = lp }
            }
            memoizeSuccessors(prev, built)
            m = built
        }
        return (m ?? [:]).sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// 上下文项：上一个词的尾字接到这个词的头字，返回罚分（>= 0）。
    /// 没见过的接续按最罕见处理 —— 否则生僻字白捡零罚分把常用字挤下去。
    private func lmPenalty(_ ctx: Character, _ fol: Character) -> Double {
        let lp = lm[String(ctx)]?[String(fol)] ?? PinyinEngine.lmFloor
        if lp >= PinyinEngine.lmRef { return 0 }
        return min(PinyinEngine.lmWeight * (PinyinEngine.lmRef - lp),
                   PinyinEngine.lmPenCap)
    }

    // MARK: - 二进制读取（小端）

    private func u32(_ off: Int) -> Int {
        guard let d = data, off >= 0, off + 4 <= d.count else { return 0 }
        return d.withUnsafeBytes { raw -> Int in
            let b = raw.bindMemory(to: UInt8.self)
            return Int(b[off]) | (Int(b[off + 1]) << 8)
                | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)
        }
    }

    private func string(_ a: Int, _ b: Int) -> String {
        guard let d = data, a >= 0, b >= a, b <= d.count else { return "" }
        return String(decoding: d[a..<b], as: UTF8.self)
    }

    private func keyAt(_ i: Int) -> String {
        string(u32(keyOffTable + 4 * i), u32(keyOffTable + 4 * (i + 1)))
    }

    /// 一条候选：词 + 对数概率。
    /// 词库里每条记录编码成「两字节对数概率 + 词」，字节落在 0x10..0x7E，
    /// 绝不会跟候选分隔符 \u{01} 撞车。
    private func candidatesAt(_ i: Int) -> [(word: String, logp: Double)] {
        let s = string(u32(valOffTable + 4 * i), u32(valOffTable + 4 * (i + 1)))
        if s.isEmpty { return [] }
        var out: [(String, Double)] = []
        for rec in s.split(separator: "\u{01}", omittingEmptySubsequences: true) {
            let a = Array(rec)
            if a.count < 3 { continue }
            let lp = decodeLogp(a[0], a[1])
            let w = String(a[2...])
            if !w.isEmpty { out.append((w, lp)) }
        }
        return out
    }

    private func lowerBound(_ prefix: String) -> Int {
        var lo = 0
        var hi = entryCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if keyAt(mid) < prefix { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func exactIndex(_ key: String) -> Int? {
        let i = lowerBound(key)
        if i < entryCount && keyAt(i) == key { return i }
        return nil
    }

    // MARK: - 对外出候选

    func candidates(for raw: String) -> [PinyinCandidate] {
        ensureMeta()
        // 主词库缺失（首次加载失败 / 内存告急被放掉）：直接给空，
        // 由 InputEngine 用 librime / 短语 / 用户词兜底，绝不在这里反复重解 27MB。
        guard ensureDict() else { return [] }
        let key = "q:" + raw
        if key == cacheKey { return cacheResult }
        if let hit = lruCache[key] { return hit }
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = qwertyCandidates(raw)
        lastDecodeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        cacheKey = key
        cacheResult = result
        lruCache[key] = result
        lruOrder.removeAll { $0 == key }
        lruOrder.append(key)
        if lruOrder.count > PinyinEngine.lruCap {
            lruCache.removeValue(forKey: lruOrder.removeFirst())
        }
        return result
    }

    /// 轻量候选：librime 就绪且候选充足时用。
    ///
    /// 词图 Beam / 前缀补全 / 兜底这些活儿 librime 干得更准，自研层这时只补
    /// 三样 librime 没有的东西：**用户记忆词**（同拼音直接顶前排）、
    /// **策展缩写词**（口语/梗/怼人）、**自定义短语**。跳过耗时的词图搜索，
    /// 打字才不会卡 —— 这是「零卡顿」的底线。
    func lightCandidates(for raw: String) -> [PinyinCandidate] {
        // 注意：这里**故意不加载主词库**（27MB）。
        // 轻量层的四样东西 —— 用户记忆词 / seed cell / 自定义短语 / 音节表 —— 
        // 全都在小层里；为了它们去解 27MB，在 librime 已经占 50MB 时就是自杀。
        ensureMeta()
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !input.isEmpty else { return [] }
        let n = input.count
        let set = IMESettingsStore.current

        // tier 分档（数值越小越优先）：
        //   0 = 精确整词（词库精确命中 / seed / 用户词 / 短语）
        //   1 = 前缀补全（你好 → 你好啊）与词图的部分覆盖片段
        //   2 = 兜底（最长可出字前缀）
        //   3 = 缩写（nh → 你好）、模糊音
        //   4 = 兜底（最后手段）
        // 商业输入法的第一屏以「精确词」为主，前缀补全和拼句不能压过它。
        var cands = [String: (cov: Int, lp: Double, pri: Bool, tier: Int)]()
        func put(_ text: String, _ cov: Int, _ lp: Double,
                 pri: Bool = false, tier: Int = 0) {
            if text.isEmpty || cov <= 0 { return }
            if let old = cands[text], old.lp >= lp, old.tier <= tier { return }
            cands[text] = (cov, lp, pri, tier)
        }

        // 策展缩写词（整串切不成音节时才用，跟全量路径同一套判断）。
        // 依赖主词库的音节表与缩写表，词库没加载就跳过（不能拿空音节集误判）。
        if ready, set.abbrevInput, !splitsIntoSyllables(input) {
            for e in abbrEdges(input) { put(e.word, n, e.logp - PinyinEngine.abbrPen, pri: true, tier: 3) }
        }
        // 用户记忆词：完整命中顶最前；打在半路上（niha）也召回学过的整词（nihao→你好）
        for (w, lp) in userWordHits(input) { put(w, n, lp, pri: true) }

        // 百度内置词条 cell：整串精确命中就顶上来（口语片段 "我也不知道啊"、
        // 成语、软件名）。librime 的词库是「词」为单位，没有成句的口语片段。
        // 4 字母以下不掺和：短串命中容易抢了常用词的位。
        if n >= 4 {
            for c in seedCandidates(input) { put(c.word, n, c.logp, pri: true) }
        }

        var hits: [(text: String, position: Int)] = []
        for p in phrases where p.code == input { hits.append((p.text, p.position)) }
        return rank(&cands, input, limit: set.candidateCount, phraseHits: hits)
    }

    /// 主程序下发的自定义短语；换一批就作废缓存重算。
    /// 一条短语的多行内容 = 多条候选：第1行排「位置」位 第2行往后依次+1
    /// （kz 三行 位置1 → 候选第1/2/3位）同一个码配多块时用位置错开
    func setPhrases(_ list: [Phrase]) {
        var out: [(String, String, Int)] = []
        for p in list {
            let code = p.cleanCode
            guard !code.isEmpty else { continue }
            let lines = p.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            let start = max(1, p.position)
            for (i, line) in lines.enumerated() {
                out.append((code, line, start + i))
            }
        }
        phrases = out
        clearCache()
        cacheResult = []
    }

    /// 输入串命中的自定义短语（合并层按「位置」把它们插回该在的名次用）
    func phraseHits(for raw: String) -> [(text: String, position: Int)] {
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !input.isEmpty else { return [] }
        return phrases.filter { $0.code == input }.map { ($0.text, $0.position) }
    }

    /// 上屏后联想：先看「这个词之后你自己常打什么」（用户上下文），
    /// 再看「这个字之后通用上常接什么」（字级 bigram），合并去重。
    func associate(_ committed: String) -> [String] {
        ensureMeta()      // 只需要字/词级 LM 小表，不碰 27MB 主词库
        let key = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = key.last else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        if let row = userBigram[key] {
            for (w, _) in row.sorted(by: { $0.value > $1.value }) where seen.insert(w).inserted {
                out.append(w)
            }
        }
        // 词级 n-gram：刚上屏的「词」之后通用上常接什么词（今天→天气）
        if wlmData != nil {
            for (w, _) in wlmSuccessors(key) where seen.insert(w).inserted {
                out.append(w)
            }
        }
        if let row = lm[String(last)] {
            for (w, _) in row.sorted(by: { $0.value > $1.value }) where seen.insert(w).inserted {
                out.append(w)
            }
        }
        return out
    }

    /// 用户记忆词召回：完整命中顶最前；输入是已学过拼音的前缀时
    /// （打 niha 就想起你常选的 nihao → 你好）也捞出来，罚分压完整命中一头。
    /// 百度「越用越顺手」的手感主要来自这一条 —— 同拼音常选哪个词，
    /// 打在半路上就该往前提，不用等打完整个拼音。
    /// 返回 [(词, 排序分)]，分已按「完整 > 前缀、补得越少越靠前」排好。
    func userWordHits(_ input: String) -> [(String, Double)] {
        var out: [(String, Double)] = []
        if let uw = userWords[input] {
            for (i, w) in uw.enumerated() { out.append((w, 900_000 - Double(i))) }
        }
        // 前缀召回只在 3 字母以上启用：n/ni 这种短输入前缀命中太杂
        guard input.count >= 3 else { return out }
        var added = 0
        for (py, ws) in userWords where py != input && py.hasPrefix(input) {
            for (i, w) in ws.enumerated() {
                guard added < 4 else { break }
                // 学过的拼音离输入越远（还要多打几个字母）排越后
                out.append((w, 600_000 - Double(i) * 100
                            - Double(py.count - input.count) * 5_000))
                added += 1
            }
            if added >= 4 { break }
        }
        return out.sorted { $0.1 > $1.1 }
    }

    /// 上一个词之后用户自己常打的词及次数（候选上下文重排用，只读）
    func userContext(after word: String) -> [String: Int]? {
        userBigram[word]
    }

    /// 字级上下文亲和度（0 或 1）：ctx 之后接 fol 在通用语料里算不算常见接续。
    /// 只对常见接续返回 1 —— 给候选排序当轻推用：不改变无用户数据时的默认序，
    /// 但「今天」之后打 tianqi，「天气」这类接得上的会浮上来。
    func contextAffinity(_ ctx: Character, _ fol: Character) -> Double {
        let lp = lm[String(ctx)]?[String(fol)] ?? PinyinEngine.lmFloor
        return lp >= PinyinEngine.lmRef ? 1.0 : 0.0
    }

    /// 记一笔用户选择，下次同拼音时往前提；同时把「拼音 -> 词」记下来，
    /// 下次打同一个拼音，这个词直接排在词典前面（百度那种越用越顺手的记忆）
    func learn(_ word: String, pinyin: String = "") {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, w.count <= 8 else { return }
        userFreq[w, default: 0] += 1

        let py = pinyin.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if !py.isEmpty, py.count <= 32 {
            var list = userWords[py] ?? []
            if let i = list.firstIndex(of: w) { list.remove(at: i) }
            list.insert(w, at: 0)
            if list.count > 8 { list = Array(list.prefix(8)) }
            userWords[py] = list
        }

        clearCache()             // 下次重算，让刚学的词立刻往前提
        persistUser()
    }

    /// 记一笔「上一个词 → 当前词」的接续习惯（InputEngine 上屏时回灌）。
    /// 这是「越用越懂你」的上下文层：上屏联想优先给用户自己的搭配。
    func learnContext(prev: String, next: String) {
        let a = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PinyinEngine.hasCJK(a), PinyinEngine.hasCJK(b),
              a.count <= 8, b.count <= 8 else { return }
        var row = userBigram[a] ?? [:]
        row[b, default: 0] += 1
        // 单个上下文最多记 12 个后继，按次数留最强的
        if row.count > 12 {
            row = Dictionary(uniqueKeysWithValues:
                row.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) })
        }
        userBigram[a] = row
        // 上下文表整体限规模：键盘内存是硬约束，别让学习记录无限膨胀
        if userBigram.count > 2000 {
            userBigram = Dictionary(uniqueKeysWithValues:
                userBigram
                    .sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }
                    .prefix(1500)
                    .map { ($0.key, $0.value) })
        }
        clearCache()
        persistUser()
    }

    private static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
    }

    /// 抹掉某个词的用户记忆（长按候选纠错用）
    func forget(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        userFreq.removeValue(forKey: w)
        for (py, list) in userWords where list.contains(w) {
            userWords[py] = list.filter { $0 != w }
        }
        userBigram.removeValue(forKey: w)
        for (k, row) in userBigram where row[w] != nil {
            userBigram[k] = row.filter { $0.key != w }
        }
        clearCache()
        persistUser()
    }

    /// 清空全部打字学习记录（主程序「清空打字学习记录」按钮触发）
    func clearLearning() {
        userFreq.removeAll()
        userWords.removeAll()
        userBigram.removeAll()
        clearCache()
        persistUser()
    }

    private func persistUser() {
        let snapshot = UserData(freq: userFreq, words: userWords, bigram: userBigram)
        userQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) {
                SharedStore.write("ime_user.json", d)
            }
        }
    }

    /// 内存告急时（系统 jetsam 红线附近）清掉解码缓存，给键盘扩展续一口命。
    /// 缓存只是「上一次拼音 → 候选」的镜像，扔了下次敲键重算即可，零功能损失。
    func trimCache() {
        clearCache()
    }

    /// 清空候选缓存（学词/换短语/换设置后必须调，否则候选是旧的）
    private func clearCache() {
        cacheKey = ""
        cacheResult = []
        lruCache.removeAll(keepingCapacity: true)
        lruOrder.removeAll(keepingCapacity: true)
    }

    // MARK: - 26 键解码

    private func qwertyCandidates(_ raw: String) -> [PinyinCandidate] {
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if input.isEmpty { return [] }
        let chars = Array(input)
        let n = chars.count
        let set = IMESettingsStore.current

        // tier 分档（数值越小越优先）：
        //   0 = 精确整词（词库精确命中 / seed / 用户词 / 短语）
        //   1 = 前缀补全（你好 → 你好啊）与词图的部分覆盖片段
        //   2 = 兜底（最长可出字前缀）
        //   3 = 缩写（nh → 你好）、模糊音
        //   4 = 兜底（最后手段）
        // 商业输入法的第一屏以「精确词」为主，前缀补全和拼句不能压过它。
        var cands = [String: (cov: Int, lp: Double, pri: Bool, tier: Int)]()
        func put(_ text: String, _ cov: Int, _ lp: Double,
                 pri: Bool = false, tier: Int = 0) {
            if text.isEmpty || cov <= 0 { return }
            if let old = cands[text], old.lp >= lp, old.tier <= tier { return }
            cands[text] = (cov, lp, pri, tier)
        }

        // 0) 自定义短语：触发码精确命中，按设置的「位置」落进候选
        var phraseHits: [(text: String, position: Int)] = []
        for p in phrases where p.code == input {
            phraseHits.append((p.text, p.position))
        }

        let splitOK = splitsIntoSyllables(input)

        // 1~2 字母：吃「短输入补全表」。它按打字概率预排（单字优先），
        // 拿 raw logP 排会被 在线/咱们 这类长词霸榜。
        if n <= 2 {
            if let ai = exactIndex(input + "\u{7f}") {
                for c in candidatesAt(ai) { put(c.word, n, c.logp) }
            }
            // nb/sb/tm/wx/nh 这类两字母缩写切不成音节，走缩写表
            if set.abbrevInput && !splitOK {
                for e in abbrEdges(input) { put(e.word, n, e.logp - PinyinEngine.abbrPen, pri: true, tier: 3) }
            }
            // 单字母 u/i/v、两字母乱码（ik/ul/vz）这些也必须有汉字
            if cands.isEmpty {
                for c in fallback(input) { put(c.word, n, c.logp, tier: 4) }
            }
            return rank(&cands, input, limit: set.candidateCount, phraseHits: phraseHits)
        }

        // 2) 前缀补全词：拼音以 input 开头的词（你好 → 你好啊/你好吗）
        for c in prefixWords(input) {
            put(c.word, n, c.logp, tier: 1)
        }

        // 2.5) 百度内置词条 cell：整串精确命中直接上来。
        //      这些是成句口语片段/成语/软件名，是全量路径里唯一的「整句口语」来源；
        //      4 字母以下不掺和，避免抢常用词的位。
        if n >= 4 {
            for c in seedCandidates(input) { put(c.word, n, c.logp, pri: true) }
        }

        tr("decode: n=\(n) splitOK=\(splitOK) cands=\(cands.count)")
        // 3) 词图 Beam Search：句子 / 前缀片段
        //    超长输入（误触长按、粘贴整段）直接跳过：代价是 O(n·width·edges)，
        //    40 个字母以上就会把扩展主线程卡到被系统打断，宁可只给前缀候选。
        let states = n <= 40 ? beam(chars) : []
        tr("decode: beam done")
        for j in 1...n {
            for (sc, ws) in states[j] {
                if ws.isEmpty { continue }
                // 没吃完整个输入的「单字」片段纯属噪声（打 awsl 蹦出 啊/阿）
                if j < n && ws.count == 1 && ws[0].count == 1 { continue }
                // 短输入（≤8 字母）不掺「3 段以上拼句」：打 nihao 用户要「你好」，
                // 不是「你/好/啊」拼出来的句子。商业输入法同样不在短串上给整句，
                // 这条是「候选栏第一屏全是长怪句」的直接原因。
                if n <= 8 && ws.count >= 3 { continue }
                // 词数罚分：同样概率下「少切、长词」更贴近真实意图（你好 优于 你 好）
                let wPen = PinyinEngine.wordPen * Double(max(0, ws.count - 1))
                put(ws.joined(), j, sc - wPen, tier: j == n ? 0 : 1)
            }
        }

        // 4) 末音节补全：末段只打了半个音节（zad → za + d → zadi 咋的；
        //    nih → ni + h → nihao 你好）。这是全拼的一部分，跟简拼开关无关。
        if !splitOK {
            for v in tailCompletions(input) {
                let d = PinyinEngine.tailPen * Double(v.count - n)
                for c in prefixWords(v) { put(c.word, n, c.logp - d, tier: 1) }
            }
        }

        // 5) 缩写/混拼：整串切不成完整音节时才用（xbzz / nmsl / wsnb / wosnb）。
        //    缩写是「猜」，罚 abbrPen 保证真音节读法压过它。
        if set.abbrevInput && !splitOK {
            for e in abbrEdges(input) { put(e.word, n, e.logp - PinyinEngine.abbrPen, pri: true, tier: 3) }
        }

        // 6) 模糊音兜底：主串候选不足 3 条才掺和
        if set.fuzzyPinyin && cands.count < 3 {
            for (vi, variant) in fuzzyVariants(input).enumerated() where vi > 0 {
                for c in prefixWords(variant) {
                    put(c.word, n, c.logp - Double(vi) * 1.0, tier: 3)
                }
            }
        }

        // 7) 智能纠错兜底：整串一个前缀都对不上时，多半是手滑了。
        //    按「错误类型」分级逐轮尝试（相邻键替换 → 相邻打反 → 多键 → 漏键），
        //    哪一轮查出词就停；越靠后的类型罚分越重，绝不压过真解。
        if set.smartCorrect && n >= 3 && (!splitOK || cands.isEmpty) {
            // 以前只在 cands 为空时才纠错 —— 但兜底/尾补全总能凑出几个垃圾词，
            // 这条分支几乎永远不执行：用户打 nihap 只能看到「纽汉浦」。
            // 现在「整串切不成音节」就纠错，而且分档压过尾补全与兜底。
            // 注意：correctedVariants 是按「位置从左到右」生成的，
            // 打错在最后一个字母时正解排在很后面。所以**不能**按命中数提前 break，
            // 只按「罚分」筛（邻键替换/相邻打反最可能），删键/漏键放第二轮。
            // 一轮跑完所有变体（邻键替换 / 相邻打反 / 删键 / 漏键都在里面），
            // 不能「先只跑低罚分的，有命中就不跑漏键」—— duibqi→对不起、wanshan→晚上
            // 恰好都是漏键，会被前面的垃圾命中挡掉，永远救不回来。
            // 代价控制：每个变体只取 2 条、总数上限 40 条。
            // 关键校验：候选字数必须等于纠正串的音节数。
            // 否则「对白」（2 字）会冒充 duibuqi（3 音节）的整串解，
            // 把真正的「对不起」压下去 —— duibqi 那条用例就是这么挂的。
            let ctier = splitOK ? 2 : 1
            var added = 0
            for v in correctedVariants(input) {
                let syl = syllableCount(v.variant)
                if syl == 0 { continue }
                for c in prefixWords(v.variant, perKey: 3) where c.word.count == syl {
                    put(c.word, n, c.logp - v.pen, tier: ctier)
                    added += 1
                }
                if added >= 40 { break }
            }
        }

        // 8) 终极兜底：查完还是没汉字（乱按 qwert/zxcvb 这种），退到最长能出字的
        //    前缀顶上。任何字母串都必须有汉字候选，绝不让面板只剩英文。
        if cands.isEmpty {
            for c in fallback(input) { put(c.word, n, c.logp, tier: 4) }
        }

        // 9) 用户自己记下的词：同样的拼音直接顶到最前；拼音前缀命中也召回
        //    （打 niha 就想起你常选的 nihao→你好，不用等打完整个拼音）。
        //    pri=true 让它进「强优先」那一档 —— 合并时排在 librime 候选前面，
        //    否则用户的选择永远被压在通用词库后面，「越用越顺手」就是句空话。
        for (w, lp) in userWordHits(input) {
            put(w, n, lp, pri: true)
        }

        return rank(&cands, input, limit: set.candidateCount, phraseHits: phraseHits)
    }

    // MARK: - 词图

    /// 音节图 + 词图：从 start 出发，所有「整词匹配」的边 (终点, 词, logP)。
    /// cap：边长硬闸（长输入时收紧，见 beam）
    private func fullEdges(_ chars: [Character], _ start: Int, cap: Int = 3000)
        -> [(j: Int, word: String, logp: Double)] {
        // 从 start 出发的所有「连续子串」里，凡是词库有的键都是候选边。
        //
        // 原来用 DFS：按音节长度递增递归拼 acc，命中就吐候选，超全局上限直接
        // `return` —— 那是**静默截断**：长输入（>15 字母）时 DFS 先钻深分支，
        // 上限一到，后面位置的边整片消失，正确切分可能在词图上根本不存在。
        // 「打长句偶尔出莫名其妙的结果」就来自这里。
        //
        // 子串枚举和 DFS 产出的边集合是同一个（形状都是连续区间），
        // 但没有递归、没有截断，而且 O(n²) 次二分比递归快一个量级。
        var out: [(Int, String, Double)] = []
        let n = chars.count
        let maxKeyLen = 24                     // 词库键最长约 24 字母（8 音节短句），再长没有意义
        var j = start + 1
        while j <= n && j - start <= maxKeyLen {
            let sub = String(chars[start..<j])
            if let idx = exactIndex(sub) {
                for c in candidatesAt(idx) {
                    out.append((j, c.word, c.logp))
                    if out.count >= cap { return out }
                }
            }
            j += 1
        }
        return out
    }

    /// 整串当缩写/混拼：把每个音节折成首字母，查 \u{7f}+缩写 表。
    /// 缩写最长放到 8 个字母（wsmbzd 这类六七个首字母的梗也得能出字）。
    private func abbrEdges(_ inp: String) -> [(word: String, logp: Double)] {
        let chars = Array(inp)
        let n = chars.count
        var out: [(String, Double)] = []
        var seen = Set<String>()
        var nodes = 0

        func go(_ pos: Int, _ ini: String) {
            nodes += 1
            if nodes > 6000 { return }
            if pos == n && ini.count >= 2 && ini.count <= 8 && !seen.contains(ini) {
                if let idx = exactIndex("\u{7f}" + ini) {
                    seen.insert(ini)
                    for c in candidatesAt(idx) { out.append((c.word, c.logp)) }
                }
            }
            if pos >= n || ini.count >= 8 { return }
            go(pos + 1, ini + String(chars[pos]))
            var L = 2
            let maxL = min(6, n - pos)
            while L <= maxL {
                let sub = String(chars[pos..<(pos + L)])
                if syllableSet.contains(sub), let f = sub.first {
                    go(pos + L, ini + String(f))
                }
                L += 1
            }
        }

        go(0, "")
        return out
    }

    /// 词图上的 Beam Search（对标 librime poet.cc 的自适应 beam）。
    /// 宽度随输入长度伸缩：短串 12 够用，长串切分路径组合爆炸，放到 20 才不丢解；
    /// 但超过 12 字母的长串反而要收紧到 10 —— 那种输入多半是整句/乱敲，
    /// 宽 beam 的边际收益没了，耗时却线性涨（键盘扩展耗不起）。
    /// 边的展开是「惰性」的：只有 states[i] 非空（即这个位置真的能到达）才去算
    /// fullEdges(chars, i)。乱按的串大部分位置根本走不到，这样能省掉大量无用 DFS。
    private func beam(_ chars: [Character])
        -> [[(Double, [String])]] {
        let n = chars.count
        if n == 0 { return [] }
        // 长句（>12 字母）原来是 width 10 / edgeCap 1200：省时间，但整句候选经常
        // 不是最优解 —— 这正是「长句组句不如百度」的直接原因。放到 14 / 1800：
        // 实测仍是一次按键毫秒级（states[i] 大多为空，边缘惰性展开），
        // 换来的候选质量提升远大于这点开销。
        // 宽度/配额按长度分级：
        //   ≤12 字母  → 12 / 3000（短输入要全，延迟本来就低）
        //   13~20    → 10 / 1200（整句为主，够用且稳在 25ms 内）
        //   >20      → 8  / 800 （超长句只求「有个合理整句」，不追极致）
        // 实测：14/1500 时长句 P50 41ms，对按键太慢。
        // 宽度是「首屏句子质量」的第一决定项。原来被 wlmLP 的逐条解析拖住，
        // 只能压到 6~12；LM 改成 O(1) 查表后，同预算下可以放到 16~20。
        let width: Int
        let edgeCap: Int
        if n <= 6 {
            width = 20; edgeCap = 2600
        } else if n <= 12 {
            width = 24; edgeCap = 2600
        } else if n <= 20 {
            width = 20; edgeCap = 2200
        } else {
            width = 14; edgeCap = 1600
        }
        var edgeCache = [[(j: Int, word: String, logp: Double)]?](repeating: nil, count: n)

        var states = [[(Double, [String])]](repeating: [], count: n + 1)
        states[0] = [(0.0, [])]
        for i in 0..<n {
            var cur = states[i]
            if cur.isEmpty { continue }
            if cur.count > width {
                cur.sort { $0.0 > $1.0 }
                cur = Array(cur.prefix(width))
                states[i] = cur
            }
            let edges: [(j: Int, word: String, logp: Double)]
            if let cached = edgeCache[i] {
                edges = cached
            } else {
                let e = fullEdges(chars, i, cap: edgeCap)
                edgeCache[i] = e
                edges = e
            }
            for (sc, ws) in cur {
                for e in edges {
                    // 上下文项：优先用词级 n-gram（前词 -> 后继词），
                    // 词级没数据（生僻前词）时退回字级 bigram（尾字 -> 头字）。
                    var pen = 0.0
                    if ws.count >= 2 {
                        // 有前两个词：优先三元（虚词歧义只有三元能判）
                        let a = ws[ws.count - 2], b = ws[ws.count - 1]
                        if let tp = trigramPenalty(a, b, e.word) {
                            pen = tp
                        }
                        pen += userPenalty(b, e.word)
                    } else if let pw = ws.last {
                        if let wp = wordPenalty(pw, e.word) {
                            pen = wp
                        } else if let lc = pw.last, let fc = e.word.first {
                            pen = lmPenalty(lc, fc)
                        }
                        pen += userPenalty(pw, e.word)
                    }
                    states[e.j].append((sc + e.logp - pen, ws + [e.word]))
                }
            }
        }
        if states[n].count > width {
            states[n].sort { $0.0 > $1.0 }
            states[n] = Array(states[n].prefix(width))
        }
        return states
    }

    /// 末音节补全：末段只打了半个音节时，把它补成所有可能的完整音节。
    ///
    /// 打 zad：最长能切成音节的前缀是 za，剩下 d 是个半截音节，
    /// 补成 di/de/da… 里 di 能拼出「咋的」—— 这就是百度/搜狗打 zad 出「咋的」的道理。
    /// 整串本来就切得开（nihao）或末段压根不是任何音节的开头（zme/wsnb）时返回空。
    private func tailCompletions(_ inp: String) -> [String] {
        let chars = Array(inp)
        let n = chars.count
        var cut = 0
        var i = 0
        while i < n {
            var hit = 0
            var len = min(6, n - i)
            while len >= 1 {
                if syllableSet.contains(String(chars[i..<(i + len)])) { hit = len; break }
                len -= 1
            }
            if hit == 0 { break }
            i += hit
            cut = i
        }
        guard cut > 0, cut < n else { return [] }
        let prefix = String(chars[0..<cut])
        let rest = String(chars[cut..<n])
        guard rest.count <= 4 else { return [] }
        // 按「补得越少越靠前、同长按字典序」排 —— Set 遍历顺序是随机的，
        // 不排的话 de/di 这种短音节可能被挤出 tailMax，打 zad 就漏了「咋的」。
        var sufs: [String] = []
        for syl in syllableSet where syl.count > rest.count && syl.hasPrefix(rest) {
            sufs.append(syl)
        }
        sufs.sort { a, b in
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
        return sufs.prefix(PinyinEngine.tailMax).map { prefix + $0 }
    }

    /// 所有拼音以 inp 开头的词（补全候选）。
    private func prefixWords(_ inp: String, capKeys: Int = 240, perKey: Int = 6)
        -> [(word: String, logp: Double)] {
        var out: [(String, Double)] = []
        var i = lowerBound(inp)
        var scanned = 0
        while i < entryCount && scanned < capKeys {
            let k = keyAt(i)
            if !k.hasPrefix(inp) { break }
            let comp = k.count - inp.count
            for c in candidatesAt(i).prefix(perKey) {
                out.append((c.word, c.logp - 0.55 * Double(comp)))
            }
            i += 1
            scanned += 1
        }
        return out
    }

    /// 最后一层兜底：任何字母串都必须出汉字，绝不让面板只剩英文。
    ///
    /// 做法是「退到最长能出字的前缀」：从长到短砍尾巴，哪一段前缀能查出候选
    /// 就用它顶上。打 qwert 这种切不成合法音节的乱码时，一路退到 q，出
    /// 去/请/钱/起…，至少是汉字，而不是光秃秃一串 qwert。
    /// 罚 fbPen×被砍掉的长度，保证它永远排在正常候选后面。
    private func fallback(_ inp: String) -> [(word: String, logp: Double)] {
        let chars = Array(inp)
        let n = chars.count
        var len = n
        while len >= 1 {
            let pre = String(chars[0..<len])
            var tries = [pre]
            if let lead = PinyinEngine.leadMap[chars[0]] {
                tries.append(lead + String(chars[1..<len]))
            }
            if pre.contains("v" as Character) {
                tries.append(pre.replacingOccurrences(of: "v", with: "u"))
            }
            for cand in tries {
                let got = prefixWords(cand)
                if !got.isEmpty {
                    let d = PinyinEngine.fbPen * Double(n - len)
                    return got.map { (word: $0.word, logp: $0.logp - d) }
                }
            }
            len -= 1
        }
        return []
    }

    // MARK: - 收尾：排序、截断、英文候选

    private func rank(_ cands: inout [String: (cov: Int, lp: Double, pri: Bool, tier: Int)],
                      _ inp: String, limit: Int,
                      phraseHits: [(text: String, position: Int)] = [])
        -> [PinyinCandidate] {
        // 用户词频加权：用得多的词往前提（只影响同覆盖度内的排序）
        if !userFreq.isEmpty {
            for (w, c) in userFreq {
                if let old = cands[w] {
                    cands[w] = (old.cov, old.lp + min(Double(c), 60.0) * 0.08,
                                old.pri, old.tier)
                }
            }
        }
        let n = inp.count
        // 策展词加成（微信/呵呵 这类：rime 词频口径偏旧，本就排在生僻同音词后面）。
        // 只抬分数不改词库字节，所以不会破坏「同键显示顺序」的既有保证。
        if !CuratedWords.set.isEmpty {
            for (w, v) in cands where w.count >= 2 && CuratedWords.set.contains(w) {
                let lifted = min(v.lp + CuratedWords.boost, CuratedWords.ceiling)
                if lifted > v.lp {
                    cands[w] = (v.cov, lifted, v.pri, v.tier)
                }
            }
        }
        var items = cands.map { (text: $0.key, cov: $0.value.cov, lp: $0.value.lp,
                                pri: $0.value.pri, tier: $0.value.tier) }
        // 排序三级：覆盖度（吃完全串的在前）→ 分档（精确词 > 前缀补全 > 兜底 > 缩写 > 纠错）
        // → 每字平均 logP（librime 的 LeftAssociateCompare 思路）→ 短词优先。
        items.sort { a, b in
            // 覆盖度优先，再分档。
            // 试过把 tier 提到 cov 前面（想让「精确词」压过「补全」），
            // 但实测纠错候选会被前缀补全挤掉：nihap → 「你哈」而不是「你好」，
            // 错拼首位从 80% 掉到 20%。所以维持 cov 优先。
            if a.cov != b.cov { return a.cov > b.cov }
            if a.tier != b.tier { return a.tier < b.tier }
            let na = a.lp / Double(a.cov)
            let nb = b.lp / Double(b.cov)
            if na != nb { return na > nb }
            if a.text.count != b.text.count { return a.text.count < b.text.count }
            return a.text < b.text
        }
        let cap = max(10, min(limit, 60))
        var result = items.prefix(cap).map {
            PinyinCandidate(word: $0.text, score: Int($0.lp * 1000),
                            consumed: $0.cov, isPriority: $0.pri)
        }
        // 自定义短语按「位置」插进候选：第1行排位置位 后面的行依次+1
        // 同名次撞车就顺延 不会互相覆盖
        for hit in phraseHits.sorted(by: { $0.position < $1.position }) {
            result.removeAll { $0.word == hit.text }
            let idx = max(0, min(hit.position - 1, result.count))
            result.insert(PinyinCandidate(word: hit.text, score: 2_000_000,
                                          consumed: n), at: idx)
        }
        if !inp.isEmpty, !result.contains(where: { $0.word == inp }) {
            result.append(PinyinCandidate(word: inp, score: Int.min,
                                          consumed: n, literal: true))
        }
        return result
    }

    // MARK: - 音节切分 / 模糊音 / 纠错

    /// 把串切成音节的个数（贪心最长匹配）；切不干净返回 0。
    /// 纠错用它校验「字数 == 音节数」，挡掉两字词冒充长拼音整串解。
    private func syllableCount(_ s: String) -> Int {
        let chars = Array(s)
        var i = 0, count = 0
        while i < chars.count {
            var len = min(6, chars.count - i)
            var hit = 0
            while len >= 1 {
                if syllableSet.contains(String(chars[i..<(i + len)])) { hit = len; break }
                len -= 1
            }
            if hit == 0 { return 0 }
            i += hit
            count += 1
        }
        return count
    }

    /// 整串能否切成「完整音节」的序列（贪心最长匹配）。
    private func splitsIntoSyllables(_ s: String) -> Bool {
        let chars = Array(s)
        let n = chars.count
        var i = 0
        while i < n {
            var hit = 0
            var len = min(6, n - i)
            while len >= 1 {
                if syllableSet.contains(String(chars[i..<(i + len)])) { hit = len; break }
                len -= 1
            }
            if hit == 0 { return false }
            i += hit
        }
        return true
    }

    /// 26 键邻键表：智能纠错用（按错旁边那个键是最常见的误触）。
    private static let keyNeighbors: [Character: String] = [
        "q": "wa",   "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg",
        "y": "tugh", "u": "yihj", "i": "uojk", "o": "ipkl", "p": "ol",
        "a": "qwsz", "s": "awedzx", "d": "serfcx", "f": "drtgvc", "g": "ftyhbv",
        "h": "gyujnb", "j": "huikmn", "k": "jiolm", "l": "kop",
        "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb", "b": "vghn",
        "n": "bhjm", "m": "njk",
    ]

    /// 智能纠错变体：覆盖四类手滑，返回「变体 + 罚分」，按错误类型从最可能到最不可能排。
    ///   1) 相邻键替换：nihap → nihao（p 挨着 o）—— 最常见
    ///   2) 相邻字母打反：niha o → nihao
    ///   3) 多打一个字母：nihao o → nihao
    ///   4) 漏打一个字母：按相邻键补一个进去
    /// 罚分递增，保证「真解」永远排在「猜出来的解」前面。
    /// 合并层（InputEngine）在 librime 候选太薄时也会调它 —— 不只是自研兜底用。
    func correctedVariants(_ s: String) -> [(variant: String, pen: Double)] {
        let chars = Array(s)
        guard chars.count >= 3, chars.count <= 12 else { return [] }
        var out: [(String, Double)] = []
        var seen = Set<String>()
        func add(_ v: String, _ pen: Double) {
            if v == s || seen.contains(v) { return }
            seen.insert(v)
            out.append((v, pen))
        }

        // 1) 相邻键替换
        for i in 0..<chars.count {
            guard let nb = PinyinEngine.keyNeighbors[chars[i]] else { continue }
            for c in nb {
                var v = chars
                v[i] = c
                add(String(v), 1.0)
            }
        }
        // 2) 相邻字母打反
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) {
                var v = chars
                v.swapAt(i, i + 1)
                add(String(v), 1.2)
            }
        }
        // 3) 多打一个字母（删掉一个）
        for i in 0..<chars.count {
            var v = chars
            v.remove(at: i)
            add(String(v), 1.6)
        }
        // 4) 漏打一个字母：候选字母 = 前一个字母的邻键 + 全部元音 + n/g。
        //    只补邻键是不够的：duibqi 少的是 u（b 的邻键里没有），
        //    wanshan 少的是 g（n 的邻键里也没有），这两类恰恰最常见。
        for i in 0...chars.count {
            let nb = i > 0 ? (PinyinEngine.keyNeighbors[chars[i - 1]] ?? "") : ""
            let src = Array(Set(Array(nb) + Array("aeioung")))
            for c in src {
                var v = chars
                v.insert(c, at: i)
                add(String(v), 2.0)
            }
        }
        return out
    }

    /// 生成容错变体：翘舌/平舌、n/l、前后鼻音（百度默认档，双向）。
    /// 跟 project.yml 里 rime_ice.custom.yaml 的 14 条 derive 保持同一套规则 ——
    /// librime 那层是编译期写死的，运行时的模糊音靠这里生成变体再查一遍。
    /// 变体越靠后罚分越多（调用方按序号罚）。
    func fuzzyVariants(_ s: String) -> [String] {
        let rules: [(String, String)] = [
            ("zh", "z"), ("z", "zh"),
            ("ch", "c"), ("c", "ch"),
            ("sh", "s"), ("s", "sh"),
            ("ang", "an"), ("an", "ang"),
            ("eng", "en"), ("en", "eng"),
            ("in", "ing"), ("ing", "in"),
            ("n", "l"), ("l", "n"),
            ("ian", "iang"), ("iang", "ian"),
            ("uan", "uang"), ("uang", "uan"),
        ]
        var out: [String] = [s]
        for (a, b) in rules {
            let snapshot = out
            for v in snapshot {
                guard out.count < 8 else { return out }
                guard let r = v.range(of: a) else { continue }
                var nv = v
                nv.replaceSubrange(r, with: b)
                if !out.contains(nv) { out.append(nv) }
            }
        }
        return out
    }

    // MARK: - 用户词频落盘

    private func loadUser() {
        guard let d = SharedStore.read("ime_user.json") else { return }
        if let o = try? JSONDecoder().decode(UserData.self, from: d) {
            userFreq = o.freq
            userWords = o.words
            userBigram = o.bigram ?? [:]
        } else if let o = try? JSONDecoder().decode([String: Int].self, from: d) {
            userFreq = o          // 兼容旧版只有词频的存档
        }
    }
}
