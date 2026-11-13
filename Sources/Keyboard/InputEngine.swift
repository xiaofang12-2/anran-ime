import Foundation

/// 键盘统一输入入口（纯本地）。
///
/// 编排两个引擎 + 一层商业级记忆：
///   · **librime**（Rime 中州韵，工业级）—— 基础候选，覆盖广、排序准；
///   · **自研 PinyinEngine** —— 兜底 + 口语/梗/策展层；
///   · **PlumLite** —— 对标百度 PlumCore 的本地交互层：同拼音置顶、
///     连续选中自动置顶、用户词频加权、上屏联想种子。
/// 全程本地，不联网、不需要账号，越用越懂你。
final class InputEngine {

    static let shared = InputEngine()
    private init() {}

    /// 上一个上屏的词：用于「上一个词 → 当前词」的用户上下文学习
    private var lastCommitted = ""

    /// 取候选（热路径）
    func candidates(for raw: String) -> [PinyinCandidate] {
        guard RimeService.shared.isReady else {
            return PinyinEngine.shared.candidates(for: raw)
        }
        let rime = RimeService.shared.candidates(raw, limit: 40)
        if rime.count >= 8 {
            let light = PinyinEngine.shared.lightCandidates(for: raw)
            return merge(rime: rime, fallback: light, raw: raw)
        }
        let fallback = PinyinEngine.shared.candidates(for: raw)
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
        // 商业级记忆：同一个音连选 3 次自动置顶，选中次数转成候选加权
        PlumLite.shared.record(pinyin: String(pinyin.prefix(used)), word: c.word)
        return used
    }

    /// 上屏后联想：拿刚上屏的词 + 末 2~4 字当种子查后继词（本地 bigram）。
    /// 对标商业输入法「打完一个词立刻给下一个」，不联网也能有云联想的观感。
    func associate(_ committed: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ list: [String]) {
            for w in list where w.count >= 2 && !seen.contains(w) {
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

    /// 长按候选：同拼音置顶 / 取消置顶（对标 ipt_set_firstword）
    func togglePin(word: String, pinyin: String) {
        PlumLite.shared.togglePin(pinyin: pinyin, word: word)
    }

    func clearLearning() {
        lastCommitted = ""
        PinyinEngine.shared.clearLearning()
        PlumLite.shared.clear()
        RimeService.shared.reset()
    }

    // MARK: - 合并

    private func merge(rime: [AnRanRimeCandidate],
                       fallback: [PinyinCandidate],
                       raw: String) -> [PinyinCandidate] {
        var out: [PinyinCandidate] = []
        var seen = Set<String>()
        func push(_ c: PinyinCandidate) {
            let w = c.word
            if w.isEmpty || seen.contains(w) { return }
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

        // 4) 用户词频：同拼音下选过的词温和前移（只动前 12 条，
        //    保留 librime 的整体排序质量，不让一次误选把正确词永久压死）
        if out.count > 1 {
            let head = Array(out.prefix(12))
            let tail = Array(out.dropFirst(12))
            let ranked = head.enumerated()
                .map { (i, c) -> (Double, PinyinCandidate) in
                    (Double(i) - PlumLite.shared.boost(pinyin: raw, word: c.word) * 1.6, c)
                }
                .sorted { $0.0 < $1.0 }
                .map { $0.1 }
            out = ranked + tail
        }

        // 5) 用户选过、但两大引擎这次没吐出来的词补回来（越用越懂你）
        for w in PlumLite.shared.userWords(pinyin: raw).prefix(3) where !seen.contains(w) {
            push(PinyinCandidate(word: w, score: 1_500_000, consumed: raw.count))
        }

        // 6) 手动置顶词绝对第一
        if let pinned = PlumLite.shared.pinned(for: raw),
           let idx = out.firstIndex(where: { $0.word == pinned }) {
            out.insert(out.remove(at: idx), at: 0)
        }

        // 7) 自定义短语按「位置」插回它该在的名次（位置 1 = 排第一）
        let hits = PinyinEngine.shared.phraseHits(for: raw)
        for hit in hits.sorted(by: { $0.position < $1.position }) {
            out.removeAll { $0.word == hit.text }
            let idx = max(0, min(hit.position - 1, out.count))
            out.insert(PinyinCandidate(word: hit.text, score: 2_000_000,
                                       consumed: raw.count), at: idx)
        }

        return Array(out.prefix(60))
    }
}
