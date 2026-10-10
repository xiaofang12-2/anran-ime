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

    init(word: String, score: Int, consumed: Int = 0, literal: Bool = false) {
        self.word = word
        self.score = score
        self.consumed = consumed
        self.literal = literal
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

    /// 自定义短语：触发码 -> 展开文本（主程序下发，见 PhraseStore）
    private var phrases: [(code: String, text: String)] = []

    private var ready = false

    private var cacheKey = ""
    private var cacheResult: [PinyinCandidate] = []

    // 用户词频（越用越准）
    private var userFreq: [String: Int] = [:]
    /// 用户自己记下的「拼音 -> 词」，打同样拼音时它们永远排在词典前面
    private var userWords: [String: [String]] = [:]
    private let userQueue = DispatchQueue(label: "anran.ime.userfreq")

    private struct UserData: Codable {
        var freq: [String: Int]
        var words: [String: [String]]
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
        ready = true

        let bundle = Bundle(for: PinyinEngine.self)
        let binURL = bundle.url(forResource: "pinyin", withExtension: "bin")
            ?? Bundle.main.url(forResource: "pinyin", withExtension: "bin")
        if let url = binURL,
           let d = try? Data(contentsOf: url, options: .mappedIfSafe),
           d.count > 44 {
            data = d
            entryCount = u32(8)
            keyOffTable = u32(12)
            valOffTable = u32(16)
            loadSyllables()
        }

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

    /// 主程序下发的自定义短语；换一批就作废缓存重算
    func setPhrases(_ list: [Phrase]) {
        phrases = list
            .map { ($0.cleanCode, $0.text) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
        cacheKey = ""
        cacheResult = []
    }

    /// 上屏后联想：拿刚上屏的末字查后继字，按接续概率从高到低
    func associate(_ committed: String) -> [String] {
        ensureLoaded()
        guard let last = committed.last, let row = lm[String(last)] else { return [] }
        return row.sorted { $0.value > $1.value }.map { $0.key }
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

    /// 抹掉某个词的用户记忆（长按候选纠错用）
    func forget(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        userFreq.removeValue(forKey: w)
        for (py, list) in userWords where list.contains(w) {
            userWords[py] = list.filter { $0 != w }
        }
        cacheKey = ""
        persistUser()
    }

    /// 清空全部打字学习记录（主程序「清空打字学习记录」按钮触发）
    func clearLearning() {
        userFreq.removeAll()
        userWords.removeAll()
        cacheKey = ""
        persistUser()
    }

    private func persistUser() {
        let snapshot = UserData(freq: userFreq, words: userWords)
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

        var cands = [String: (cov: Int, lp: Double)]()
        func put(_ text: String, _ cov: Int, _ lp: Double) {
            if text.isEmpty || cov <= 0 { return }
            if let old = cands[text], old.lp >= lp { return }
            cands[text] = (cov, lp)
        }

        // 0) 自定义短语：触发码精确命中直接顶最前
        for (code, text) in phrases where code == input {
            put(text, n, 1_000_000)
        }

        // 1~2 字母：吃「短输入补全表」。它按打字概率预排（单字优先），
        // 拿 raw logP 排会被 在线/咱们 这类长词霸榜。
        if n <= 2 {
            if let ai = exactIndex(input + "\u{7f}") {
                for c in candidatesAt(ai) { put(c.word, n, c.logp) }
            }
            // nb/sb/tm/wx/nh 这类两字母缩写切不成音节，走缩写表
            if !splitsIntoSyllables(input) {
                for e in abbrEdges(input) { put(e.word, n, e.logp) }
            }
            return rank(&cands, input, limit: set.candidateCount)
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
                put(ws.joined(), j, sc)
            }
        }

        // 4) 缩写/混拼兜底：整串切不成完整音节时才用
        if !splitsIntoSyllables(input) {
            for e in abbrEdges(input) { put(e.word, n, e.logp) }
        }

        // 5) 模糊音兜底：主串候选不足 3 条才掺和
        if set.fuzzyPinyin && cands.count < 3 {
            for (vi, variant) in fuzzyVariants(input).enumerated() where vi > 0 {
                for c in prefixWords(variant) {
                    put(c.word, n, c.logp - Double(vi) * 1.0)
                }
            }
        }

        // 6) 智能纠错兜底：整串一个前缀都对不上时，多半按错了相邻键
        if set.smartCorrect && cands.isEmpty && n >= 3 {
            for variant in correctedVariants(input) {
                for c in prefixWords(variant) { put(c.word, n, c.logp) }
            }
        }

        // 7) 用户自己记下的词：同样的拼音直接顶到最前
        if let uw = userWords[input] {
            for (i, w) in uw.enumerated() {
                put(w, n, 900_000 - Double(i))
            }
        }

        return rank(&cands, input, limit: set.candidateCount)
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
    private func abbrEdges(_ inp: String) -> [(word: String, logp: Double)] {
        let chars = Array(inp)
        let n = chars.count
        var out: [(String, Double)] = []
        var seen = Set<String>()
        var nodes = 0

        func go(_ pos: Int, _ ini: String) {
            nodes += 1
            if nodes > 4000 { return }
            if pos == n && ini.count >= 2 && ini.count <= 5 && !seen.contains(ini) {
                if let idx = exactIndex("\u{7f}" + ini) {
                    seen.insert(ini)
                    for c in candidatesAt(idx) { out.append((c.word, c.logp)) }
                }
            }
            if pos >= n || ini.count >= 5 { return }
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

    /// 词图上的 Beam Search（librime poet.cc 的 kMaxLineCandidates=7，这里取 12）。
    private func beam(_ chars: [Character], width: Int = 12)
        -> [[(Double, [String])]] {
        let n = chars.count
        if n == 0 { return [] }
        var edges = (0..<n).map { fullEdges(chars, $0) }
        // 缩写只在整串切不成完整音节时才算边，否则 gun 会被读成 g(gu)+n
        // 缩写表里 g n 一抓一大把（国内/功能/概念…）把 滚 挤下去。
        if n >= 2 && !splitsIntoSyllables(String(chars)) {
            let ab = abbrEdges(String(chars))
            edges[0] += ab.map { (n, $0.word, $0.logp) }
        }

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
            for (sc, ws) in cur {
                for e in edges[i] {
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

    // MARK: - 收尾：排序、截断、英文候选

    private func rank(_ cands: inout [String: (cov: Int, lp: Double)],
                      _ inp: String, limit: Int) -> [PinyinCandidate] {
        // 用户词频加权：用得多的词往前提（只影响同覆盖度内的排序）
        if !userFreq.isEmpty {
            for (w, c) in userFreq {
                if let old = cands[w] {
                    cands[w] = (old.cov, old.lp + min(Double(c), 60.0) * 0.08)
                }
            }
        }
        let n = inp.count
        var items = cands.map { (text: $0.key, cov: $0.value.cov, lp: $0.value.lp) }
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
            PinyinCandidate(word: $0.text, score: Int($0.lp * 1000), consumed: $0.cov)
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

    private func correctedVariants(_ s: String) -> [String] {
        let chars = Array(s)
        guard chars.count >= 3, chars.count <= 12 else { return [] }
        var out: [String] = []
        for i in 0..<chars.count {
            guard let nb = PinyinEngine.keyNeighbors[chars[i]] else { continue }
            for c in nb {
                var v = chars
                v[i] = c
                out.append(String(v))
            }
        }
        return out
    }

    /// 生成容错变体：翘舌/平舌、前后鼻音、n/l、f/h。变体越靠后罚分越多。
    private func fuzzyVariants(_ s: String) -> [String] {
        let rules: [(String, String)] = [
            ("zh", "z"), ("ch", "c"), ("sh", "s"),
            ("ang", "an"), ("eng", "en"), ("ing", "in"),
            ("iang", "ian"), ("uang", "uan"),
            ("n", "l"), ("f", "h"),
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
        } else if let o = try? JSONDecoder().decode([String: Int].self, from: d) {
            userFreq = o          // 兼容旧版只有词频的存档
        }
    }
}
