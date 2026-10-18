import Foundation

/// 一条候选词
struct PinyinCandidate {
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

    /// 字级 bigram 语言模型：上下文首字 -> {后继字: log P(后继 | 上下文)}。
    /// 词图打分的「上下文项」（对标 librime grammar.h 的 Grammar::Evaluate）。
    private var lm: [String: [String: Double]] = [:]

    /// 自定义短语：触发码 -> 展开文本 + 命中后落位（主程序下发，见 PhraseStore）
    private var phrases: [(code: String, text: String, position: Int)] = []

    private var ready = false

    private var cacheKey = ""
    private var cacheResult: [PinyinCandidate] = []

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
    private static let lmWeight = 0.3

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
    /// 词数罚分：同样概率下「少切、长词」更贴近真实意图（你好 优于 你 好）
    private static let wordPen = 0.5

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

    // MARK: - 词库加载

    private func ensureLoaded() {
        if ready { return }

        let bundle = Bundle(for: PinyinEngine.self)
        let binURL = bundle.url(forResource: "pinyin", withExtension: "bin")
            ?? Bundle.main.url(forResource: "pinyin", withExtension: "bin")
        if let url = binURL,
           let d = try? Data(contentsOf: url, options: .mappedIfSafe),
           d.count > 44, d.prefix(4) == Data("ANPY".utf8) {
            data = d
            entryCount = u32(8)
            keyOffTable = u32(12)
            valOffTable = u32(16)
            loadSyllables()
        } else {
            // 词库没读到就别把 ready 立起来 —— 否则整块键盘永远只剩英文字母。
            // 下次敲键会再试一遍（例如扩展刚起来时 bundle 还没就绪）。
            return
        }
        ready = true
        cacheKey = ""

        let assocURL = bundle.url(forResource: "assoc", withExtension: "bin")
            ?? Bundle.main.url(forResource: "assoc", withExtension: "bin")
        if let url = assocURL {
            loadAssoc(url)
        }
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

    /// 上下文项：上一个词的尾字接到这个词的头字，返回罚分（>= 0）。
    /// 没见过的接续按最罕见处理 —— 否则生僻字白捡零罚分把常用字挤下去。
    private func lmPenalty(_ ctx: Character, _ fol: Character) -> Double {
        let lp = lm[String(ctx)]?[String(fol)] ?? PinyinEngine.lmFloor
        if lp >= PinyinEngine.lmRef { return 0 }
        return PinyinEngine.lmWeight * (PinyinEngine.lmRef - lp)
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
        ensureLoaded()
        let key = "q:" + raw
        if key == cacheKey { return cacheResult }
        let result = qwertyCandidates(raw)
        cacheKey = key
        cacheResult = result
        return result
    }

    /// 轻量候选：librime 就绪且候选充足时用。
    ///
    /// 词图 Beam / 前缀补全 / 兜底这些活儿 librime 干得更准，自研层这时只补
    /// 三样 librime 没有的东西：**用户记忆词**（同拼音直接顶前排）、
    /// **策展缩写词**（口语/梗/怼人）、**自定义短语**。跳过耗时的词图搜索，
    /// 打字才不会卡 —— 这是「零卡顿」的底线。
    func lightCandidates(for raw: String) -> [PinyinCandidate] {
        ensureLoaded()
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        guard !input.isEmpty else { return [] }
        let n = input.count
        let set = IMESettingsStore.current

        var cands = [String: (cov: Int, lp: Double, pri: Bool)]()
        func put(_ text: String, _ cov: Int, _ lp: Double, pri: Bool = false) {
            if text.isEmpty || cov <= 0 { return }
            if let old = cands[text], old.lp >= lp { return }
            cands[text] = (cov, lp, pri)
        }

        // 策展缩写词（整串切不成音节时才用，跟全量路径同一套判断）
        if set.abbrevInput && !splitsIntoSyllables(input) {
            for e in abbrEdges(input) { put(e.word, n, e.logp - PinyinEngine.abbrPen, pri: true) }
        }
        // 用户记忆词：同样的拼音直接顶到最前
        if let uw = userWords[input] {
            for (i, w) in uw.enumerated() { put(w, n, 900_000 - Double(i), pri: true) }
        }

        var hits: [(text: String, position: Int)] = []
        for p in phrases where p.code == input { hits.append((p.text, p.position)) }
        return rank(&cands, input, limit: set.candidateCount, phraseHits: hits)
    }

    /// 主程序下发的自定义短语；换一批就作废缓存重算。
    /// 多行内容按 position（从第几行开始）先切好 上屏时直接就是切完的
    func setPhrases(_ list: [Phrase]) {
        phrases = list
            .map { p -> (String, String, Int) in
                let lines = p.text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let start = min(max(p.position, 1), max(lines.count, 1))
                let cut = start > 1 && lines.count > 1
                    ? lines[(start - 1)...].joined(separator: "\n")
                    : p.text
                return (p.cleanCode, cut, max(1, p.position))
            }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
        cacheKey = ""
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
        ensureLoaded()
        let key = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = key.last else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        if let row = userBigram[key] {
            for (w, _) in row.sorted(by: { $0.value > $1.value }) where seen.insert(w).inserted {
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

        cacheKey = ""            // 下次重算，让刚学的词立刻往前提
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
        cacheKey = ""
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
        cacheKey = ""
        persistUser()
    }

    /// 清空全部打字学习记录（主程序「清空打字学习记录」按钮触发）
    func clearLearning() {
        userFreq.removeAll()
        userWords.removeAll()
        userBigram.removeAll()
        cacheKey = ""
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

    // MARK: - 26 键解码

    private func qwertyCandidates(_ raw: String) -> [PinyinCandidate] {
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if input.isEmpty { return [] }
        let chars = Array(input)
        let n = chars.count
        let set = IMESettingsStore.current

        var cands = [String: (cov: Int, lp: Double, pri: Bool)]()
        func put(_ text: String, _ cov: Int, _ lp: Double, pri: Bool = false) {
            if text.isEmpty || cov <= 0 { return }
            if let old = cands[text], old.lp >= lp { return }
            cands[text] = (cov, lp, pri)
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
                for e in abbrEdges(input) { put(e.word, n, e.logp - PinyinEngine.abbrPen, pri: true) }
            }
            // 单字母 u/i/v、两字母乱码（ik/ul/vz）这些也必须有汉字
            if cands.isEmpty {
                for c in fallback(input) { put(c.word, n, c.logp) }
            }
            return rank(&cands, input, limit: set.candidateCount, phraseHits: phraseHits)
        }

        // 2) 前缀补全词：拼音以 input 开头的词（你好 → 你好啊/你好吗）
        for c in prefixWords(input) {
            put(c.word, n, c.logp)
        }

        // 3) 词图 Beam Search：句子 / 前缀片段
        let states = beam(chars)
        for j in 1...n {
            for (sc, ws) in states[j] {
                if ws.isEmpty { continue }
                // 没吃完整个输入的「单字」片段纯属噪声（打 awsl 蹦出 啊/阿）
                if j < n && ws.count == 1 && ws[0].count == 1 { continue }
                // 词数罚分：同样概率下「少切、长词」更贴近真实意图（你好 优于 你 好）
                let wPen = PinyinEngine.wordPen * Double(max(0, ws.count - 1))
                put(ws.joined(), j, sc - wPen)
            }
        }

        // 4) 末音节补全：末段只打了半个音节（zad → za + d → zadi 咋的；
        //    nih → ni + h → nihao 你好）。这是全拼的一部分，跟简拼开关无关。
        if !splitOK {
            for v in tailCompletions(input) {
                let d = PinyinEngine.tailPen * Double(v.count - n)
                for c in prefixWords(v) { put(c.word, n, c.logp - d) }
            }
        }

        // 5) 缩写/混拼：整串切不成完整音节时才用（xbzz / nmsl / wsnb / wosnb）。
        //    缩写是「猜」，罚 abbrPen 保证真音节读法压过它。
        if set.abbrevInput && !splitOK {
            for e in abbrEdges(input) { put(e.word, n, e.logp - PinyinEngine.abbrPen, pri: true) }
        }

        // 6) 模糊音兜底：主串候选不足 3 条才掺和
        if set.fuzzyPinyin && cands.count < 3 {
            for (vi, variant) in fuzzyVariants(input).enumerated() where vi > 0 {
                for c in prefixWords(variant) {
                    put(c.word, n, c.logp - Double(vi) * 1.0)
                }
            }
        }

        // 7) 智能纠错兜底：整串一个前缀都对不上时，多半是手滑了。
        //    按「错误类型」分级逐轮尝试（相邻键替换 → 相邻打反 → 多键 → 漏键），
        //    哪一轮查出词就停；越靠后的类型罚分越重，绝不压过真解。
        if set.smartCorrect && cands.isEmpty && n >= 3 {
            for v in correctedVariants(input) {
                for c in prefixWords(v.variant) { put(c.word, n, c.logp - v.pen) }
                if cands.count >= 3 { break }
            }
        }

        // 8) 终极兜底：查完还是没汉字（乱按 qwert/zxcvb 这种），退到最长能出字的
        //    前缀顶上。任何字母串都必须有汉字候选，绝不让面板只剩英文。
        if cands.isEmpty {
            for c in fallback(input) { put(c.word, n, c.logp) }
        }

        // 9) 用户自己记下的词：同样的拼音直接顶到最前。
        //    pri=true 让它进「强优先」那一档 —— 合并时排在 librime 候选前面，
        //    否则用户的选择永远被压在通用词库后面，「越用越顺手」就是句空话。
        if let uw = userWords[input] {
            for (i, w) in uw.enumerated() {
                put(w, n, 900_000 - Double(i), pri: true)
            }
        }

        return rank(&cands, input, limit: set.candidateCount, phraseHits: phraseHits)
    }

    // MARK: - 词图

    /// 音节图 + 词图：从 start 出发，所有「整词匹配」的边 (终点, 词, logP)。
    private func fullEdges(_ chars: [Character], _ start: Int)
        -> [(j: Int, word: String, logp: Double)] {
        var out: [(Int, String, Double)] = []
        let n = chars.count

        func dfs(_ pos: Int, _ acc: String) {
            if out.count > 3000 { return }
            if !acc.isEmpty, let idx = exactIndex(acc) {
                for c in candidatesAt(idx) { out.append((pos, c.word, c.logp)) }
            }
            if pos >= n { return }
            var L = 1
            let maxL = min(6, n - pos)
            while L <= maxL {
                let sub = String(chars[pos..<(pos + L)])
                if syllableSet.contains(sub) { dfs(pos + L, acc + sub) }
                L += 1
            }
        }

        dfs(start, "")
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
    /// 宽度随输入长度伸缩：短串 12 够用，长串切分路径组合爆炸，放到 20 才不丢解。
    /// 边的展开是「惰性」的：只有 states[i] 非空（即这个位置真的能到达）才去算
    /// fullEdges(chars, i)。乱按的串大部分位置根本走不到，这样能省掉大量无用 DFS。
    private func beam(_ chars: [Character])
        -> [[(Double, [String])]] {
        let n = chars.count
        if n == 0 { return [] }
        let width = min(20, max(12, n * 2))
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
                let e = fullEdges(chars, i)
                edgeCache[i] = e
                edges = e
            }
            for (sc, ws) in cur {
                for e in edges {
                    // grammar.h 的上下文项：上一个词的尾字接这个词的头字
                    var pen = 0.0
                    if let lc = ws.last?.last, let fc = e.word.first {
                        pen = lmPenalty(lc, fc)
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

    private func rank(_ cands: inout [String: (cov: Int, lp: Double, pri: Bool)],
                      _ inp: String, limit: Int,
                      phraseHits: [(text: String, position: Int)] = [])
        -> [PinyinCandidate] {
        // 用户词频加权：用得多的词往前提（只影响同覆盖度内的排序）
        if !userFreq.isEmpty {
            for (w, c) in userFreq {
                if let old = cands[w] {
                    cands[w] = (old.cov, old.lp + min(Double(c), 60.0) * 0.08, old.pri)
                }
            }
        }
        let n = inp.count
        var items = cands.map { (text: $0.key, cov: $0.value.cov, lp: $0.value.lp, pri: $0.value.pri) }
        // 先看覆盖度（吃完全串的排前），再看每字平均 logP（librime 的 LeftAssociateCompare 思路）
        items.sort { a, b in
            if a.cov != b.cov { return a.cov > b.cov }
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
        // 自定义短语整块顶到候选最前 按短语本里的顺序排
        // 同一个码配的多条依次往下排（position 现在是「从第几行开始」 不再管候选名次）
        if !phraseHits.isEmpty {
            var block: [PinyinCandidate] = []
            var seen = Set<String>()
            for hit in phraseHits where seen.insert(hit.text).inserted {
                block.append(PinyinCandidate(word: hit.text, score: 2_000_000,
                                             consumed: n))
            }
            result.removeAll { c in block.contains { $0.word == c.word } }
            result.insert(contentsOf: block, at: 0)
        }
        if !inp.isEmpty, !result.contains(where: { $0.word == inp }) {
            result.append(PinyinCandidate(word: inp, score: Int.min,
                                          consumed: n, literal: true))
        }
        return result
    }

    // MARK: - 音节切分 / 模糊音 / 纠错

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

    /// 智能纠错：覆盖四类手滑，返回「变体 + 罚分」，按错误类型从最可能到最不可能排。
    ///   1) 相邻键替换：nihap → nihao（p 挨着 o）—— 最常见
    ///   2) 相邻字母打反：niha o → nihao
    ///   3) 多打一个字母：nihao o → nihao
    ///   4) 漏打一个字母：按相邻键补一个进去
    /// 罚分递增，保证「真解」永远排在「猜出来的解」前面。
    private func correctedVariants(_ s: String) -> [(variant: String, pen: Double)] {
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
        // 4) 漏打一个字母（在相邻键里补一个进去）
        for i in 0...chars.count {
            let src = i > 0 ? PinyinEngine.keyNeighbors[chars[i - 1]] : nil
            for c in (src ?? "aeioun") {
                var v = chars
                v.insert(c, at: i)
                add(String(v), 2.0)
            }
        }
        return out
    }

    /// 生成容错变体：翘舌/平舌、前后鼻音、n/l、f/h。变体越靠后罚分越多。
    private func fuzzyVariants(_ s: String) -> [String] {
        let rules: [(String, String)] = [
            ("zh", "z"), ("ch", "c"), ("sh", "s"),
            ("n", "l"), ("r", "l"), ("f", "h"),
            ("ang", "an"), ("eng", "en"), ("ing", "in"),
            ("iang", "ian"), ("uang", "uan"),
        ]
        var out: [String] = [s]
        for (a, b) in rules {
            let snapshot = out
            for v in snapshot {
                guard out.count < 10 else { return out }
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
