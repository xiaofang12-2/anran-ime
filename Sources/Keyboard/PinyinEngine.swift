import Foundation

/// 一条候选词
struct PinyinCandidate {
    let word: String
    let score: Int
    /// 是不是「原样英文」候选（中英混输时把拼音串本身也能直接上屏）
    let literal: Bool

    init(word: String, score: Int, literal: Bool = false) {
        self.word = word
        self.score = score
        self.literal = literal
    }
}

/// 键盘形态
enum KBMode: String {
    case qwerty   // 26 键
    case t9       // 9 键
}

/// 本地拼音引擎
///
/// 词库 `Support/dict/pinyin.bin` 用 `mappedIfSafe` 内存映射，不整块读进堆 ——
/// 键盘扩展只有 30~60MB 内存，这是硬约束。
/// 联想表 `Support/dict/assoc.bin` 很小（字 -> 常用后继字），启动一次性读进字典。
///
/// 出候选的路子：
///   1. 前缀/完全匹配（含模糊音变体）
///   2. 音节切分拼词（26 键）
///   3. 9 键数字串按音节展开
/// 再叠加「用户词频」加权，用得多的词自动往前提。
final class PinyinEngine {

    static let shared = PinyinEngine()

    private var data: Data?
    private var entryCount = 0
    private var keyOffTable = 0
    private var valOffTable = 0

    private var syllableSet = Set<String>()
    /// (数字编码, 音节)，9 键用
    private var t9Index: [(digits: String, syl: String)] = []

    private var assoc: [String: [String]] = [:]

    private var ready = false

    private var cacheKey = ""
    private var cacheResult: [PinyinCandidate] = []

    // 用户词频（越用越准）
    private var userFreq: [String: Int] = [:]
    private let userQueue = DispatchQueue(label: "anran.ime.userfreq")

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
        var list: [String] = []
        list.reserveCapacity(sylCount)
        var set = Set<String>()
        set.reserveCapacity(sylCount)
        for i in 0..<sylCount {
            let s = string(u32(sylOffTable + 4 * i), u32(sylOffTable + 4 * (i + 1)))
            if !s.isEmpty {
                list.append(s)
                set.insert(s)
            }
        }
        syllableSet = set
        t9Index = list.map { (digits: t9Digits($0), syl: $0) }
    }

    private func loadAssoc(_ url: URL) {
        guard let d = try? Data(contentsOf: url), d.count > 4 else { return }
        let text = String(decoding: d.dropFirst(4), as: UTF8.self)
        var map = [String: [String]]()
        for rec in text.split(separator: "\u{03}") {
            guard let sep = rec.firstIndex(of: "\u{02}") else { continue }
            let key = String(rec[rec.startIndex..<sep])
            guard !key.isEmpty else { continue }
            let rest = rec[rec.index(after: sep)...]
            let follows = rest.split(separator: "\u{01}").map(String.init)
            if !follows.isEmpty { map[key] = follows }
        }
        assoc = map
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

    private func candidatesAt(_ i: Int) -> [String] {
        let s = string(u32(valOffTable + 4 * i), u32(valOffTable + 4 * (i + 1)))
        if s.isEmpty { return [] }
        return s.split(separator: "\u{01}").map(String.init)
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

    func candidates(for raw: String, mode: KBMode) -> [PinyinCandidate] {
        ensureLoaded()
        let key = mode == .t9 ? "9:" + raw : "q:" + raw
        if key == cacheKey { return cacheResult }
        let result = mode == .t9 ? t9Candidates(raw) : qwertyCandidates(raw)
        cacheKey = key
        cacheResult = result
        return result
    }

    /// 上屏后联想：拿刚上屏的末字查后继字
    func associate(_ committed: String) -> [String] {
        ensureLoaded()
        guard let last = committed.last else { return [] }
        return assoc[String(last)] ?? []
    }

    /// 记一笔用户选择，下次同拼音时往前提
    func learn(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, w.count <= 8 else { return }
        userFreq[w, default: 0] += 1
        let snapshot = userFreq
        userQueue.async {
            if let d = try? JSONEncoder().encode(snapshot) {
                SharedStore.write("ime_user.json", d)
            }
        }
    }

    // MARK: - 26 键

    private func qwertyCandidates(_ raw: String) -> [PinyinCandidate] {
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if input.isEmpty { return [] }

        var scored = [String: Int]()

        // 1) 前缀/完全匹配，带模糊音变体
        for (vi, variant) in fuzzyVariants(input).enumerated() {
            let penalty = vi * 7_000
            var i = lowerBound(variant)
            var scanned = 0
            while i < entryCount && scanned < 120 {
                let k = keyAt(i)
                if !k.hasPrefix(variant) { break }
                let exact = (k == variant)
                let base = (exact ? 900_000
                                  : 620_000 - (k.count - variant.count) * 2_000) - penalty
                let cands = candidatesAt(i)
                let take = exact ? cands.count : min(cands.count, 3)
                for idx in 0..<take {
                    let s = base - idx * 120
                    let w = cands[idx]
                    if let old = scored[w], old >= s { continue }
                    scored[w] = s
                }
                i += 1
                scanned += 1
            }
        }

        // 2) 音节切分（只在原串上做，避免组合爆炸）
        if input.count <= 24 {
            for (phrase, sc) in segment(Array(input)) {
                let s = 300_000 + sc
                if let old = scored[phrase], old >= s { continue }
                scored[phrase] = s
            }
        }

        return finish(&scored, literal: input)
    }

    // MARK: - 9 键

    private func t9Candidates(_ raw: String) -> [PinyinCandidate] {
        let digits = String(raw.filter { $0 >= "0" && $0 <= "9" })
        if digits.isEmpty { return [] }
        var scored = [String: Int]()
        for (phrase, sc) in t9Segment(Array(digits)) {
            let s = 320_000 + sc
            if let old = scored[phrase], old >= s { continue }
            scored[phrase] = s
        }
        return finish(&scored, literal: digits)
    }

    private func t9Segment(_ chars: [Character]) -> [(String, Int)] {
        var memo = [Int: [(String, Int)]]()

        func go(_ start: Int) -> [(String, Int)] {
            if let m = memo[start] { return m }
            if start >= chars.count {
                memo[start] = [("", 0)]
                return [("", 0)]
            }
            var out: [(String, Int)] = []
            let maxLen = min(6, chars.count - start)
            var len = 1
            while len <= maxLen {
                let chunk = String(chars[start..<(start + len)])
                for item in t9Index where item.digits.hasPrefix(chunk) {
                    guard let idx = exactIndex(item.syl) else { continue }
                    let cands = candidatesAt(idx)
                    let take = min(cands.count, 3)
                    if take == 0 { continue }
                    let rest = go(start + len)
                    if rest.isEmpty { continue }
                    for k in 0..<take {
                        let base = k == 0 ? 100 : (k == 1 ? 55 : 25)
                        for (rp, rs) in rest {
                            out.append((cands[k] + rp, base + rs))
                        }
                    }
                }
                len += 1
            }
            if out.count > 24 {
                out.sort { $0.1 > $1.1 }
                out = Array(out.prefix(24))
            }
            memo[start] = out
            return out
        }

        return go(0)
    }

    // MARK: - 收尾：加权、排序、截断、英文候选

    private func finish(_ scored: inout [String: Int],
                        literal: String) -> [PinyinCandidate] {
        // 用户词频加权
        if !userFreq.isEmpty {
            for (w, c) in userFreq {
                if let base = scored[w] {
                    scored[w] = base + min(c, 60) * 1_500
                }
            }
        }

        var result = scored.map { PinyinCandidate(word: $0.key, score: $0.value) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.word.count != b.word.count { return a.word.count < b.word.count }
                return a.word < b.word
            }
        if result.count > 40 { result = Array(result.prefix(40)) }

        // 中英混输：拼音串本身永远排在最后，随时能直接上屏
        if !literal.isEmpty, !result.contains(where: { $0.word == literal }) {
            result.append(PinyinCandidate(word: literal, score: Int.min, literal: true))
        }
        return result
    }

    // MARK: - 26 键音节切分

    private func segment(_ chars: [Character]) -> [(String, Int)] {
        var memo = [Int: [(String, Int)]]()

        func go(_ start: Int) -> [(String, Int)] {
            if let m = memo[start] { return m }
            if start >= chars.count {
                memo[start] = [("", 0)]
                return [("", 0)]
            }
            var out: [(String, Int)] = []
            let maxLen = min(6, chars.count - start)
            var len = 1
            while len <= maxLen {
                let syl = String(chars[start..<(start + len)])
                if syllableSet.contains(syl), let idx = exactIndex(syl) {
                    let cands = candidatesAt(idx)
                    let take = min(cands.count, 3)
                    if take > 0 {
                        let rest = go(start + len)
                        if !rest.isEmpty {
                            for k in 0..<take {
                                let base = k == 0 ? 100 : (k == 1 ? 55 : 25)
                                for (rp, rs) in rest {
                                    out.append((cands[k] + rp, base + rs))
                                }
                            }
                        }
                    }
                }
                len += 1
            }
            if out.count > 16 {
                out.sort { $0.1 > $1.1 }
                out = Array(out.prefix(16))
            }
            memo[start] = out
            return out
        }

        return go(0)
    }

    // MARK: - 模糊音

    /// 生成容错变体：翘舌/平舌、前后鼻音、n/l、f/h。
    /// 变体越靠后罚分越多，保证原串永远最优先。
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

    // MARK: - 9 键数字编码

    private static let t9Map: [Character: Character] = [
        "a": "2", "b": "2", "c": "2",
        "d": "3", "e": "3", "f": "3",
        "g": "4", "h": "4", "i": "4",
        "j": "5", "k": "5", "l": "5",
        "m": "6", "n": "6", "o": "6",
        "p": "7", "q": "7", "r": "7", "s": "7",
        "t": "8", "u": "8", "v": "8",
        "w": "9", "x": "9", "y": "9", "z": "9",
    ]

    private func t9Digits(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if let d = PinyinEngine.t9Map[ch] { out.append(d) }
        }
        return out
    }

    // MARK: - 用户词频落盘

    private func loadUser() {
        guard let d = SharedStore.read("ime_user.json"),
              let o = try? JSONDecoder().decode([String: Int].self, from: d)
        else { return }
        userFreq = o
    }
}