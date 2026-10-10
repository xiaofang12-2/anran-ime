import Foundation

/// 一条候选词
struct PinyinCandidate {
    let word: String
    let score: Int
}

/// 本地拼音引擎
///
/// 词库是构建期生成的紧凑二进制（`Support/dict/pinyin.bin`），运行时用
/// `mappedIfSafe` 内存映射，不整块读进堆 —— 键盘扩展只有 30~60MB 内存，
/// 这一条是硬约束。
///
/// 出候选走两条路：
///   1. 前缀/完全匹配：用户敲的整串拼音直接命中词条（nihao -> 你好）
///   2. 音节切分：把拼音串切成合法音节再拼（woshi -> 我+是 = 我是）
final class PinyinEngine {

    static let shared = PinyinEngine()

    private var data: Data?
    private var entryCount = 0
    private var keyOffTable = 0
    private var valOffTable = 0
    private var syllableSet = Set<String>()
    private var ready = false

    private var cacheInput = ""
    private var cacheResult: [PinyinCandidate] = []

    private init() {}

    // MARK: - 词库加载

    private func ensureLoaded() {
        if ready { return }
        ready = true
        let bundle = Bundle(for: PinyinEngine.self)
        guard let url = bundle.url(forResource: "pinyin", withExtension: "bin")
                ?? Bundle.main.url(forResource: "pinyin", withExtension: "bin"),
              let d = try? Data(contentsOf: url, options: .mappedIfSafe),
              d.count > 44 else { return }

        data = d
        entryCount = u32(8)
        keyOffTable = u32(12)
        valOffTable = u32(16)

        let sylCount = u32(28)
        let sylOffTable = u32(32)
        if sylCount > 0 && sylCount < 20000 {
            var set = Set<String>()
            set.reserveCapacity(sylCount)
            for i in 0..<sylCount {
                let s = string(u32(sylOffTable + 4 * i), u32(sylOffTable + 4 * (i + 1)))
                if !s.isEmpty { set.insert(s) }
            }
            syllableSet = set
        }
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

    /// 第一个 key >= prefix 的位置
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

    // MARK: - 出候选

    func candidates(for raw: String) -> [PinyinCandidate] {
        ensureLoaded()
        let input = raw.lowercased().filter { $0 >= "a" && $0 <= "z" }
        if input.isEmpty { return [] }
        if input == cacheInput { return cacheResult }

        var scored = [String: Int]()

        // 1) 前缀 / 完全匹配
        var i = lowerBound(input)
        var scanned = 0
        while i < entryCount && scanned < 120 {
            let k = keyAt(i)
            if !k.hasPrefix(input) { break }
            let exact = (k == input)
            let base = exact ? 900_000 : 620_000 - (k.count - input.count) * 2_000
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

        // 2) 音节切分（整串切成合法音节再拼词）
        if input.count <= 24 {
            let chars = Array(input)
            for (phrase, sc) in segment(chars) {
                let s = 300_000 + sc
                if let old = scored[phrase], old >= s { continue }
                scored[phrase] = s
            }
        }

        var result = scored.map { PinyinCandidate(word: $0.key, score: $0.value) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.word.count != b.word.count { return a.word.count < b.word.count }
                return a.word < b.word
            }
        if result.count > 40 { result = Array(result.prefix(40)) }

        // 一个都匹配不上就把原串当候选，方便直接上屏英文
        if result.isEmpty {
            result = [PinyinCandidate(word: input, score: 0)]
        }

        cacheInput = input
        cacheResult = result
        return result
    }

    /// 把一个拼音串切成音节，返回拼好的词与分数（内部带 memo，避免指数爆炸）
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
}