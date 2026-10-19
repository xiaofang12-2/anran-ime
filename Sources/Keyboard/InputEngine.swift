import Foundation

/// 键盘统一输入入口。
///
/// 编排两个引擎：
///   · **librime**（Rime 中州韵内核，工业级）—— 基础候选，覆盖广、排序准；
///   · **自研 PinyinEngine** —— 兜底 + 口语/梗/怼人策展层。
///
/// 合并规则（这是本项目跟百度/搜狗掰手腕的关键）：
///   1. 自研「强优先」候选顶到最前 —— 用户自己记下的词（同拼音你常选哪个），
///      以及缩写表命中的策展词（小逼崽子 / 我是你爸 / nmsl 这类）；
///      librime 的通用词库没有策展词，也记不住「你偏好哪个同音词」；
///   2. 其余走 librime 的候选顺序（比自研词图排得准）；
///   3. 自研剩下的候选（含「任何字母都出汉字」的兜底保证）垫在后面；
///   4. 自定义短语按用户设的「位置」强制插回它该在的名次。
///
/// librime 没起来（部署失败 / 包里没带词库）时，整条链路退回纯自研引擎，
/// 行为跟以前一模一样 —— 主功能永不可用性为零。
final class InputEngine {

    static let shared = InputEngine()
    private init() {}

    /// 上一个上屏的词：用于「上一个词 → 当前词」的用户上下文学习
    private var lastCommitted = ""

    /// 取候选（热路径）
    func candidates(for raw: String) -> [PinyinCandidate] {
        // librime 没起来：整条链路退回纯自研引擎
        guard RimeService.shared.isReady else {
            return PinyinEngine.shared.candidates(for: raw)
        }

        let rime = RimeService.shared.candidates(raw, limit: 40)
        if rime.count >= 8 {
            // librime 候选够多：自研层只补「用户记忆 / 策展缩写 / 短语」，
            // 跳过耗时的词图搜索 —— 既保住 librime 的排序质量，又让打字不卡
            let light = PinyinEngine.shared.lightCandidates(for: raw)
            return merge(rime: rime, fallback: light, raw: raw)
        }

        // librime 候选稀薄（生僻串 / 刚部署完）：自研全量兜底，保证永远有字可出
        let fallback = PinyinEngine.shared.candidates(for: raw)
        if rime.isEmpty { return fallback }
        return merge(rime: rime, fallback: fallback, raw: raw)
    }

    /// 上屏一个候选，返回「吃掉」了多少个拼音字符（支持部分上屏）。
    /// - 来自 librime 的候选：交给 librime 选中（它顺手学词），用剩下的输入算吃掉的长度；
    /// - 来自自研层的候选：走自研的学词。
    func commit(_ c: PinyinCandidate, pinyin: String) -> Int {
        // 用户上下文学习：上一个上屏词 → 当前词（纯本地，越用越懂你）
        if !lastCommitted.isEmpty, lastCommitted != c.word {
            PinyinEngine.shared.learnContext(prev: lastCommitted, next: c.word)
        }
        lastCommitted = c.word

        let n = pinyin.count
        if let idx = c.rimeIndex {
            RimeService.shared.select(index: idx)
            let rest = RimeService.shared.currentInput()
            let used = n - rest.count
            let u = (used > 0 && used <= n)
                ? used
                : (c.consumed > 0 && c.consumed <= n ? c.consumed : n)
            // 自研层也记一笔。librime 有自己的用户词典，但我们这层的「记忆优先」
            // 靠这份「拼音 -> 词」映射才能在下次同拼音时把用户常选的词顶上来 ——
            // 走 librime 选中的词不记，用户的选择就永远上不了前排。
            PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(u)))
            return u
        }
        let used = (c.consumed > 0 && c.consumed <= n) ? c.consumed : n
        PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(used)))
        return used
    }

    /// 上屏后联想：拿刚上屏的末字查后继字（自研 bigram，够快够小）
    func associate(_ committed: String) -> [String] {
        PinyinEngine.shared.associate(committed)
    }

    /// 句子结束（标点/回车）：上下文断层，清掉上一个词，
    /// 别让新句子的候选还跟着上一个句子的尾巴排
    func clearContext() {
        lastCommitted = ""
    }

    /// 上下文加权分：上一个上屏词 → 当前候选词。
    /// 用户自己的搭配重奖（打完「今天」你常打「天气」，直接改变组内顺序），
    /// 通用字级接续轻推（尾字接头字接得上的浮一浮）。两者都没有就返回 0，
    /// 组内保持引擎原序 —— 不破坏无用户数据时的默认排序。
    private func contextBoost(_ word: String) -> Double {
        guard !lastCommitted.isEmpty, let fol = word.first else { return 0 }
        var b = 0.0
        if let c = PinyinEngine.shared.userContext(after: lastCommitted)?[word] {
            b += min(Double(c), 6.0) * 3.0
        }
        if let ctx = lastCommitted.last {
            b += PinyinEngine.shared.contextAffinity(ctx, fol) * 0.8
        }
        return b
    }

    func forget(_ word: String) { PinyinEngine.shared.forget(word) }
    func setPhrases(_ list: [Phrase]) { PinyinEngine.shared.setPhrases(list) }
    func clearLearning() {
        lastCommitted = ""
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

        // 2) librime 候选，带上 rime 下标，选中时回灌给它学词。
        //    组内按「上下文加权」重排：用户自己的搭配 > 通用接续 > librime 原序
        //    （rimeIndex 保持 librime 里的原始下标，回灌/部分上屏都靠它）。
        //    这就是百度「越用越懂你」的核心：打完「今天」打 tianqi，「天气」顶前排。
        let rimeRanked = rime.enumerated()
            .map { (idx: $0.offset, cand: $0.element, boost: contextBoost($0.element.text)) }
            .sorted { a, b in
                if a.boost != b.boost { return a.boost > b.boost }
                return a.idx < b.idx        // 同分保持 librime 原顺序
            }
        for e in rimeRanked {
            push(PinyinCandidate(word: e.cand.text, score: 0,
                                 consumed: raw.count, literal: false, rimeIndex: e.idx))
        }

        // 3) 自研其余候选（含兜底保证，绝不让面板只剩英文）。
        //    这组的概率序是词图 beam 精算出来的，上下文加分只当组内裁决，
        //    不整组重排 —— 罕见串/ librime 没起来时的正确率不能被上下文带偏。
        //    Swift 的 sort 不保证稳定，相等加权时用原始下标决胜，保住 rank() 原序。
        let fallbackRanked = fallback
            .filter { !$0.isPriority }
            .enumerated()
            .map { (idx: $0.offset, cand: $0.element, boost: contextBoost($0.element.word)) }
            .sorted { a, b in
                if a.boost != b.boost { return a.boost > b.boost }
                return a.idx < b.idx
            }
        for e in fallbackRanked { push(e.cand) }

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
