import Foundation

/// 键盘统一输入入口。
///
/// 编排两个引擎：
///   · **librime**（Rime 中州韵内核，工业级）—— 基础候选，覆盖广、排序准；
///   · **自研 PinyinEngine** —— 兜底 + 口语/梗/怼人策展层。
///
/// 合并规则（这是本项目跟百度/搜狗掰手腕的关键）：
///   1. 自研「缩写表命中的策展词」（小逼崽子 / 我是你爸 / nmsl 这类）顶到最前 ——
///      librime 的通用词库没有这些，只有我们的策展层有；
///   2. 其余走 librime 的候选顺序（比自研词图排得准）；
///   3. 自研剩下的候选（含「任何字母都出汉字」的兜底保证）垫在后面；
///   4. 自定义短语按用户设的「位置」强制插回它该在的名次。
///
/// librime 没起来（部署失败 / 包里没带词库）时，整条链路退回纯自研引擎，
/// 行为跟以前一模一样 —— 主功能永不可用性为零。
final class InputEngine {

    static let shared = InputEngine()
    private init() {}

    /// 取候选（热路径）
    func candidates(for raw: String) -> [PinyinCandidate] {
        let fallback = PinyinEngine.shared.candidates(for: raw)
        guard RimeService.shared.isReady else { return fallback }

        let rime = RimeService.shared.candidates(raw, limit: 40)
        if rime.isEmpty { return fallback }
        return merge(rime: rime, fallback: fallback, raw: raw)
    }

    /// 上屏一个候选，返回「吃掉」了多少个拼音字符（支持部分上屏）。
    /// - 来自 librime 的候选：交给 librime 选中（它顺手学词），用剩下的输入算吃掉的长度；
    /// - 来自自研层的候选：走自研的学词。
    func commit(_ c: PinyinCandidate, pinyin: String) -> Int {
        let n = pinyin.count
        if let idx = c.rimeIndex {
            RimeService.shared.select(index: idx)
            let rest = RimeService.shared.currentInput()
            let used = n - rest.count
            if used > 0 && used <= n { return used }
            return c.consumed > 0 && c.consumed <= n ? c.consumed : n
        }
        let used = (c.consumed > 0 && c.consumed <= n) ? c.consumed : n
        PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(used)))
        return used
    }

    /// 上屏后联想：拿刚上屏的末字查后继字（自研 bigram，够快够小）
    func associate(_ committed: String) -> [String] {
        PinyinEngine.shared.associate(committed)
    }

    func forget(_ word: String) { PinyinEngine.shared.forget(word) }
    func setPhrases(_ list: [Phrase]) { PinyinEngine.shared.setPhrases(list) }
    func clearLearning() {
        PinyinEngine.shared.clearLearning()
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

        // 1) 策展强优先（缩写表命中）：小逼崽子 / 我是你爸 这类必须压过 librime
        for c in fallback where c.isPriority { push(c) }

        // 2) librime 候选，带上 rime 下标，选中时回灌给它学词
        for (i, c) in rime.enumerated() {
            push(PinyinCandidate(word: c.text, score: 0,
                                 consumed: raw.count, literal: false, rimeIndex: i))
        }

        // 3) 自研其余候选（含兜底保证，绝不让面板只剩英文）
        for c in fallback where !c.isPriority { push(c) }

        // 4) 自定义短语按「位置」插回它该在的名次（位置 1 = 排第一）
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
