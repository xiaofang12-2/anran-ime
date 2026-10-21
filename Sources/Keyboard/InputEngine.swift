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

    /// 智能造词链：连续几次上屏的「词 + 吃掉的那段拼音」。
    /// 一段拼音拼完（ composing 清空）时若拼出个 2~8 字的整词，
    /// 就按整串拼音学进用户词典 —— 百度「选字选着选着就成词」靠的就是这个。
    private var chainWords: [String] = []
    private var chainPy = ""

    /// 取候选（热路径）
    func candidates(for raw: String) -> [PinyinCandidate] {
        // 整条解码链会有大量临时对象（词图状态、路径数组、候选字典）。
        // 包一层 autoreleasepool：每次按键结束就把这些临时对象放掉，
        // 不让它们堆到自动释放池边界（扩展的 jetsam 红线只有 60~70MB）。
        autoreleasepool {
            limitWordLength(candidatesInner(for: raw), raw: raw)
        }
    }

    /// 短输入的字数硬约束：候选字数不能远大于输入字母数。
    /// 打 3 个字母（yua）却把「原来的把你不能」顶到第一位，是候选栏最刺眼的问题 —— 
    /// 全拼平均 2~3 字母一个字，这里按 0.8 字/字母留足余量（3 字母→3 字、4 字母→4 字），
    /// 只挡「明显不成比例的长句」。n > 6 不限制（长句本来该出现）。
    /// isPriority（用户置顶/策展词/自定义短语）与 literal 不受限。
    private func limitWordLength(_ list: [PinyinCandidate],
                                 raw: String) -> [PinyinCandidate] {
        let n = raw.count
        guard n > 0, n <= 6 else { return list }
        let cap = max(2, Int(Double(n) * 0.8) + 1)
        return list.filter {
            $0.isPriority || $0.literal || $0.word.count <= cap
        }
    }

    private func candidatesInner(for raw: String) -> [PinyinCandidate] {
        // librime 没起来：整条链路退回纯自研引擎
        guard RimeService.shared.isReady else {
            return applyPin(PinyinEngine.shared.candidates(for: raw), raw: raw)
        }

        let set = IMESettingsStore.current
        let rime = RimeService.shared.candidates(raw, limit: 40)
        if rime.count >= 8 {
            // librime 候选够多：自研层只补「用户记忆 / 策展缩写 / 短语」，
            // 跳过耗时的词图搜索 —— 既保住 librime 的排序质量，又让打字不卡
            let light = PinyinEngine.shared.lightCandidates(for: raw)
            return applyPin(merge(rime: rime, fallback: light, raw: raw), raw: raw)
        }

        // librime 候选稀薄（生僻串 / 手滑打错 / 模糊音）：先在合并层把
        // 模糊音变体和纠错变体查一遍 librime，罚分后垫在正主候选后面。
        // 这是「模糊音 / 智能纠错开关对主力引擎真生效」的关键 ——
        // rime 的 speller/algebra 是编译期规则，运行时可改的只有我们这层。
        var fuzzy: [PinyinCandidate] = []
        if rime.count < 4 {
            if set.fuzzyPinyin {
                // 最多试 3 个变体、每个取 5 条：变体查询有代价，纠正是掺和不是主角
                for (i, v) in PinyinEngine.shared.fuzzyVariants(raw).enumerated() {
                    guard i > 0, i <= 3 else { continue }
                    for c in RimeService.shared.candidates(v, limit: 5) {
                        fuzzy.append(PinyinCandidate(word: c.text, score: -Int((1.5 + Double(i) * 0.8) * 1000),
                                                     consumed: raw.count))
                    }
                }
            }
            // 模糊音没救回来再试手滑纠错（相邻键四类），更少更慢，罚更重
            if set.smartCorrect, fuzzy.isEmpty {
                for v in PinyinEngine.shared.correctedVariants(raw).prefix(3) {
                    for c in RimeService.shared.candidates(v.variant, limit: 5) {
                        fuzzy.append(PinyinCandidate(word: c.text, score: -Int((2.5 + v.pen) * 1000),
                                                     consumed: raw.count))
                    }
                }
            }
        }

        // librime 候选稀薄（生僻串 / 刚部署完）：自研全量兜底，保证永远有字可出
        let fallback = PinyinEngine.shared.candidates(for: raw)
        if rime.isEmpty && fuzzy.isEmpty { return applyPin(fallback, raw: raw) }
        return applyPin(merge(rime: rime, fallback: fallback, raw: raw, fuzzy: fuzzy), raw: raw)
    }

    /// 置顶词压到第一位（对标 PlumCore 的 `ipt_set_firstword`）。
    /// 不走 merge 也要生效：librime 没起来时同样要让用户亲手置顶的词站第一格。
    private func applyPin(_ list: [PinyinCandidate], raw: String) -> [PinyinCandidate] {
        guard let pin = PlumLite.shared.pinned(for: raw), !pin.isEmpty else { return list }
        var out = list.filter { $0.word != pin }
        out.insert(PinyinCandidate(word: pin, score: 2_100_000,
                                   consumed: raw.count, isPriority: true), at: 0)
        return Array(out.prefix(60))
    }

    /// 长按候选：在该拼音下置顶 / 取消置顶（再点一次取消）
    func togglePin(word: String, pinyin: String) {
        PlumLite.shared.togglePin(pinyin: pinyin, word: word)
    }

    func isPinned(word: String, pinyin: String) -> Bool {
        PlumLite.shared.isPinned(pinyin: pinyin, word: word)
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
        var used = n
        if let idx = c.rimeIndex {
            RimeService.shared.select(index: idx)
            let rest = RimeService.shared.currentInput()
            used = n - rest.count
            let u = (used > 0 && used <= n)
                ? used
                : (c.consumed > 0 && c.consumed <= n ? c.consumed : n)
            // 自研层也记一笔。librime 有自己的用户词典，但我们这层的「记忆优先」
            // 靠这份「拼音 -> 词」映射才能在下次同拼音时把用户常选的词顶上来 ——
            // 走 librime 选中的词不记，用户的选择就永远上不了前排。
            PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(u)))
            used = u
        } else {
            used = (c.consumed > 0 && c.consumed <= n) ? c.consumed : n
            PinyinEngine.shared.learn(c.word, pinyin: String(pinyin.prefix(used)))
        }

        // PlumLite：同拼音下的选择偏好（对标 ipt_adjust_cnword）。
        // 连续 3 次选同一个词就自动置顶 —— 百度「越用越懂你」的收敛速度。
        PlumLite.shared.record(pinyin: String(pinyin.prefix(max(1, used))), word: c.word)

        // 智能造词链：只有汉字片段能进链；英文/符号上屏立即断链
        // （链里混进非汉字就拼不出词，留着只会污染下一次评估）
        let pureCJK = !c.word.isEmpty && c.word.unicodeScalars.allSatisfy({
            $0.value >= 0x4E00 && $0.value <= 0x9FFF
        })
        if !pureCJK {
            resetChain()
        } else {
            chainWords.append(c.word)
            chainPy += String(pinyin.prefix(used))
            // 一段输入拼完了（composing 将清空）：评估要不要把链上的碎片拼成整词
            if used >= n {
                formWordIfWorthwhile()
                resetChain()
            }
        }
        return used
    }

    /// 把连续上屏的碎片拼成一个整词学进去（对标百度「选字成词」）。
    /// 只有「2~6 段、总共 2~8 个汉字、每段都是汉字」才学 ——
    /// 单段（本来就是一个词）不用学，超长的多半是误连也不学。
    private func formWordIfWorthwhile() {
        guard chainWords.count >= 2, chainWords.count <= 6 else { return }
        let joined = chainWords.joined()
        guard joined.count >= 2, joined.count <= 8 else { return }
        guard chainPy.count >= 2, chainPy.count <= 32 else { return }
        // 每段都必须是汉字：混进英文/符号的链是误连（打 "OK 好的" 不该学出 "OK好的"）
        for w in chainWords {
            guard !w.isEmpty, w.unicodeScalars.allSatisfy({
                $0.value >= 0x4E00 && $0.value <= 0x9FFF
            }) else { return }
        }
        PinyinEngine.shared.learn(joined, pinyin: chainPy)
    }

    /// 上屏后联想：拿刚上屏的末字查后继字（自研 bigram，够快够小）。
    /// PlumLite 再按「句内关键词」（末 2~4 字）补一轮 —— 对标
    /// `ipt_keyword_get_sentence_keyword`：整句场景下按词联想比按单字准。
    func associate(_ committed: String) -> [String] {
        var out = PinyinEngine.shared.associate(committed)
        for seed in PlumLite.shared.lianSeeds(committed) {
            if out.count >= 8 { break }
            for w in PinyinEngine.shared.associate(seed) where !out.contains(w) {
                out.append(w)
                if out.count >= 8 { break }
            }
        }
        return out
    }

    /// 句子结束（标点/回车/空格）：上下文断层，清掉上一个词，
    /// 别让新句子的候选还跟着上一个句子的尾巴排；造词链一并作废
    func clearContext() {
        lastCommitted = ""
        chainWords = []
        chainPy = ""
    }

    /// 只作废造词链，不动上下文学习（空格、删字这类词中断点用）
    func resetChain() {
        chainWords = []
        chainPy = ""
    }

    /// 上下文加权分：上一个上屏词 → 当前候选词（含 PlumLite 的同拼音选择偏好）。
    /// 用户自己的搭配重奖（打完「今天」你常打「天气」，直接改变组内顺序），
    /// 通用字级接续轻推（尾字接头字接得上的浮一浮）。两者都没有就返回 0，
    /// 组内保持引擎原序 —— 不破坏无用户数据时的默认排序。
    /// 奖励随次数递减（log 刻度）：第 1 次搭配就够改命，第 8 次也只比第 4 次
    /// 强一丝 —— 线性加分会让「偶然连打两次」的词永久霸榜。
    private func contextBoost(_ word: String, raw: String) -> Double {
        var b = PlumLite.shared.boost(pinyin: raw, word: word)
        guard !lastCommitted.isEmpty, let fol = word.first else { return b }
        if let c = PinyinEngine.shared.userContext(after: lastCommitted)?[word] {
            b += Self.boostForCount(c)
        }
        if let ctx = lastCommitted.last {
            b += PinyinEngine.shared.contextAffinity(ctx, fol) * 0.8
        }
        // 词级接续亲和（上屏词 -> 候选词）：直接命中常见搭配（今天→天气）浮一浮
        b += PinyinEngine.shared.wordAffinity(lastCommitted, word) * 0.8
        return b
    }

    /// 用户搭配次数 → 加权分（递减曲线）
    private static func boostForCount(_ c: Int) -> Double {
        let k = min(c, 8)
        let table: [Double] = [0, 3.0, 4.2, 5.0, 5.6, 6.0, 6.3, 6.5, 6.6]
        return table[k]
    }

    func forget(_ word: String) { PinyinEngine.shared.forget(word) }
    func setPhrases(_ list: [Phrase]) { PinyinEngine.shared.setPhrases(list) }
    func clearLearning() {
        lastCommitted = ""
        chainWords = []
        chainPy = ""
        PinyinEngine.shared.clearLearning()
        PlumLite.shared.clear()
        RimeService.shared.reset()
    }

    // MARK: - 合并

    private func merge(rime: [AnRanRimeCandidate],
                       fallback: [PinyinCandidate],
                       raw: String,
                       fuzzy: [PinyinCandidate] = []) -> [PinyinCandidate] {
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
            .map { (idx: $0.offset, cand: $0.element, boost: contextBoost($0.element.text, raw: raw)) }
            .sorted { a, b in
                if a.boost != b.boost { return a.boost > b.boost }
                return a.idx < b.idx        // 同分保持 librime 原顺序
            }
        for e in rimeRanked {
            push(PinyinCandidate(word: e.cand.text, score: 0,
                                 consumed: raw.count, literal: false, rimeIndex: e.idx))
        }

        // 2.5) 模糊音 / 智能纠错变体查出来的 librime 候选：正主候选太薄时
        //     才掺和（变体查询有代价），罚分已编进 score，名次固定在正主之后。
        //     rimeIndex 置 nil —— 它们是变体输入查出来的，选中时不能拿变体
        //     会话回灌；走自研学词路径，按用户真正打的原串拼音记。
        for c in fuzzy { push(c) }

        // 3) 自研其余候选（含兜底保证，绝不让面板只剩英文）。
        //    这组的概率序是词图 beam 精算出来的，上下文加分只当组内裁决，
        //    不整组重排 —— 罕见串/ librime 没起来时的正确率不能被上下文带偏。
        //    Swift 的 sort 不保证稳定，相等加权时用原始下标决胜，保住 rank() 原序。
        let fallbackRanked = fallback
            .filter { !$0.isPriority }
            .enumerated()
            .map { (idx: $0.offset, cand: $0.element, boost: contextBoost($0.element.word, raw: raw)) }
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
