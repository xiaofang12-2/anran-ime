import Foundation

/// 键盘统一输入入口（纯本地）。
///
/// 编排两个引擎 + 一层商业级记忆：
///   · librime（Rime 中州韵）—— 基础候选、整句与语言模型打分；
///   · 自研 PinyinEngine —— 兜底 + 口语/梗/策展层；
///   · PlumLite —— 同拼音置顶、连续选中自动置顶、用户词频、联想种子。
///
/// 候选出口统一过 `isClean`：表情、颜文字、装饰符号一律不进候选栏。
final class InputEngine {

    static let shared = InputEngine()
    private init() {}

    /// 上一个上屏的词：用于「上一个词 → 当前词」的用户上下文学习
    private var lastCommitted = ""

    // MARK: - 候选准入（零表情）

    /// 汉字（含扩展 A/B）、ASCII 字母数字、常用中英标点才允许进候选栏。
    /// emoji / dingbat / 变体选择符 / 私用区 / 半角片假名（颜文字）全部拒掉。
    private static let allowedPunct: Set<Int> = [
        0x20, 0x21, 0x22, 0x23, 0x25, 0x26, 0x27, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x3A, 0x3B, 0x3D, 0x3F, 0x40, 0x5F,
        0x00B7, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026,
        0x3001, 0x3002, 0x300A, 0x300B, 0x3010, 0x3011,
        0xFF01, 0xFF08, 0xFF09, 0xFF0C, 0xFF1A, 0xFF1B, 0xFF1F, 0xFF5E
    ]

    static func isClean(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        for u in word.unicodeScalars {
            let v = Int(u.value)
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { continue }
            if (0x20000...0x2A6DF).contains(v) { continue }
            if (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) { continue }
            if (0x30...0x39).contains(v) { continue }
            if Self.allowedPunct.contains(v) { continue }
            return false
        }
        return true
    }

    // MARK: - 取候选（热路径）

    func candidates(for raw: String) -> [PinyinCandidate] {
        guard RimeService.shared.isReady else {
            return PinyinEngine.shared.candidates(for: raw).filter { Self.isClean($0.word) }
        }
        // 源头先拦一次表情，避免 rime 的 emoji 滤镜漏网后污染排序与计数
        let rime = RimeService.shared.candidates(raw, limit: 40)
            .filter { Self.isClean($0.text) }
        if rime.count >= 8 {
            let light = PinyinEngine.shared.lightCandidates(for: raw)
                .filter { Self.isClean($0.word) }
            return merge(rime: rime, fallback: light, raw: raw)
        }
        let fallback = PinyinEngine.shared.candidates(for: raw)
            .filter { Self.isClean($0.word) }
        if rime.isEmpty { return fallback }
        return merge(rime: rime, fallback: fallback, raw: raw)
    }

    /// 上屏一个候选，返回「吃掉」了多少个拼音字符（支持部分上屏）。
    func commit(_ c: PinyinCandidate, pinyin: String) -> Int {
        if !lastCommitted.isEmpty, lastCommitted != c.word {
            PinyinEngine.shared.learnContext(prev: lastCommitted, next: c.word)
        }
        lastCommitted = c.word

        let n = pinyin.count
        var used = 0
        if let idx = c.rimeIndex {
            RimeService.shared.select(index: idx)
            let rest = RimeService.shared.currentInput()
            let u = n - rest.count
            used = (u > 0 && u <= n) ? u : (c.consumed > 0 && c.consumed <= n ? c.consumed : n)
            PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(used)))
        } else {
            used = (c.consumed > 0 && c.consumed <= n) ? c.consumed : n
            PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(used)))
        }
        // 同一个音连选 3 次自动置顶，选中次数转成候选加权
        PlumLite.shared.record(pinyin: String(pinyin.prefix(used)), word: c.word)
        return used
    }

    /// 上屏后联想：拿刚上屏的词 + 末 2~4 字当种子查后继词（本地 bigram）。
    func associate(_ committed: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ list: [String]) {
            for w in list where w.count >= 2 && Self.isClean(w) && !seen.contains(w) {
                seen.insert(w)
                out.append(w)
                if out.count >= 9 { return }
            }
        }
        add(PinyinEngine.shared.associate(committed))
        // 末 4 字 → 末 2 字，长种子先试（更贴合刚打出来的短语）
        for seed in PlumLite.shared.lianSeeds(committed).reversed() {
            if out.count >= 9 { break }
            add(PinyinEngine.shared.associate(seed))
        }
        return Array(out.prefix(9))
    }

    func forget(_ word: String) { PinyinEngine.shared.forget(word) }
    func setPhrases(_ list: [Phrase]) { PinyinEngine.shared.setPhrases(list) }

    /// 标点 / 回车 / 符号之后：造词链断掉，但保留上下文
    func clearContext() { lastCommitted = "" }

    /// 空格 / 退格：连打链整个作废，librime 的组词上下文也一起重置
    func resetChain() {
        lastCommitted = ""
        RimeService.shared.reset()
    }

    /// 长按候选：同拼音置顶 / 取消置顶
    func togglePin(word: String, pinyin: String) {
        PlumLite.shared.togglePin(pinyin: pinyin, word: word)
    }

    func clearLearning() {
        lastCommitted = ""
        PinyinEngine.shared.clearLearning()
        PlumLite.shared.clear()
        RimeService.shared.reset()
    }

    // MARK: - 合并与重排

    private func merge(rime: [AnRanRimeCandidate],
                       fallback: [PinyinCandidate],
                       raw: String) -> [PinyinCandidate] {
        var out: [PinyinCandidate] = []
        var seen = Set<String>()
        func push(_ c: PinyinCandidate) {
            let w = c.word
            if w.isEmpty || seen.contains(w) || !Self.isClean(w) { return }
            seen.insert(w)
            out.append(c)
        }

        // 1) 策展强优先（缩写表命中）
        for c in fallback where c.isPriority { push(c) }

        // 2) librime 候选
        for (i, c) in rime.enumerated() {
            push(PinyinCandidate(word: c.text, score: 0,
                                 consumed: raw.count, literal: false, rimeIndex: i))
        }

        // 3) 自研其余候选（含「任何字母都出汉字」的兜底保证）
        for c in fallback where !c.isPriority { push(c) }

        // 4) 商业级第一屏重排：长串下多字整词/整句提前、单字退后、用户记忆加权
        out = polish(out, raw: raw)

        // 5) 用户选过、但两大引擎这次没吐出来的词补回来
        for w in PlumLite.shared.userWords(pinyin: raw).prefix(3)
            where !seen.contains(w) && Self.isClean(w) {
            push(PinyinCandidate(word: w, score: 1_500_000, consumed: raw.count))
        }

        // 6) 手动置顶词绝对第一
        if let pinned = PlumLite.shared.pinned(for: raw),
           let idx = out.firstIndex(where: { $0.word == pinned }) {
            out.insert(out.remove(at: idx), at: 0)
        }

        // 7) 自定义短语按「位置」插回它该在的名次。
        //    这是用户自己写的内容，不受候选准入过滤限制。
        let hits = PinyinEngine.shared.phraseHits(for: raw)
        for hit in hits.sorted(by: { $0.position < $1.position }) {
            out.removeAll { $0.word == hit.text }
            let idx = max(0, min(hit.position - 1, out.count))
            out.insert(PinyinCandidate(word: hit.text, score: 2_000_000,
                                       consumed: raw.count), at: idx)
        }

        return Array(out.prefix(60))
    }

    /// 只重排前 24 条：保留 librime 的整体排序质量，同时把「打长串却前面全是单字」
    /// 这个最伤手感的毛病压下去。尾部候选原序不动。
    private func polish(_ list: [PinyinCandidate], raw: String) -> [PinyinCandidate] {
        guard list.count > 1 else { return list }
        let n = raw.count
        let headN = min(24, list.count)
        let head = Array(list.prefix(headN))
        let tail = Array(list.dropFirst(headN))
        let ranked = head.enumerated()
            .map { (i, c) -> (Double, PinyinCandidate) in
                var s = Double(i)
                let len = c.word.count
                if len >= 4 { s -= 3.0 }              // 四字以上：整句 / 成语 / 长词
                else if len == 3 { s -= 2.0 }
                else if len == 2 { s -= 0.7 }
                else { s += (n >= 8 ? 4.5 : 0.4) }   // 长拼音串把单字压后
                s -= PlumLite.shared.boost(pinyin: raw, word: c.word) * 1.8
                return (s, c)
            }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
        return ranked + tail
    }
}
