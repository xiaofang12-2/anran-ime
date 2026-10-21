import Foundation

/// PlumLite —— 对标百度 PlumCore 的本地交互层
///
/// 逆向自 APK 内伪装成 `assets/ipt/inputcore_20160219` 的 ARM ELF，
/// 其导出的 JNI 是 `com.baidu.input.PlumCore.Pl*`，内部 C API 为 `ipt_*`。
/// 本文件把其中「跟中文拼音打字直接相关」的几件事在 iOS 侧重写：
///
/// | PlumCore (Android)                  | 本项目                                        |
/// |-------------------------------------|-----------------------------------------------|
/// | `ipt_set_firstword` / cancel_first  | `pin` / `unpin`（同拼音首位置顶）              |
/// | `ipt_adjust_cnword`（选择调权）      | `record`（连续选中 → 自动置顶 + 权重累加）      |
/// | `ipt_usword_getstr`（用户词优先）    | `boost`（合并层加分）                          |
/// | `ipt_query_findlian`（联想）         | 复用 `PinyinEngine.associate`，按末二词做种子   |
///
/// 只做「排序与记忆」，不做解码 —— 解码仍由 librime / PinyinEngine 负责，
/// 这样内存零膨胀（键盘扩展 60~70MB jetsam 红线），也不会互相打架。
final class PlumLite {

    static let shared = PlumLite()

    /// 单个拼音串最多记几条候选权重（键盘内存是硬约束）
    private static let rowCap = 12
    /// 整个表最多多少个拼音串
    private static let keyCap = 800
    /// 同一拼音下连续选中几次就把该词自动置顶（百度「越用越懂你」的收敛速度）
    private static let autoPinStreak = 3

    /// 拼音串 -> 候选词 -> 选中次数
    private var hits: [String: [String: Int]] = [:]
    /// 拼音串 -> 手动/自动置顶词
    private var pins: [String: String] = [:]
    /// 拼音串 -> 上一次选中的词（算连续次数用）
    private var last: [String: String] = [:]
    /// 拼音串 -> 连续选中同一个词的次数
    private var streak: [String: Int] = [:]

    private var dirty = false
    private var saveTick = 0

    private init() { load() }

    // MARK: - 对外

    /// 置顶（长按候选触发，对标 `ipt_set_firstword`）。再置顶同一个词等于取消。
    func togglePin(pinyin: String, word: String) {
        let py = Self.norm(pinyin)
        guard !py.isEmpty, !word.isEmpty else { return }
        if pins[py] == word {
            pins.removeValue(forKey: py)
        } else {
            pins[py] = word
        }
        markDirty()
        persistSoon()
    }

    func isPinned(pinyin: String, word: String) -> Bool {
        pins[Self.norm(pinyin)] == word
    }

    /// 该拼音串当前被置顶的词（合并层直接把这条提到第一位）
    func pinned(for pinyin: String) -> String? {
        pins[Self.norm(pinyin)]
    }

    /// 选中记一笔。连续 3 次在同一拼音下选同一个词 → 自动置顶，
    /// 这就是百度「同一个音你老是选它，下次它就在第一个」的行为。
    func record(pinyin: String, word: String) {
        let py = Self.norm(pinyin)
        guard !py.isEmpty, !word.isEmpty, word.count <= 12 else { return }
        var row = hits[py] ?? [:]
        row[word, default: 0] += 1
        if row.count > Self.rowCap {
            row = Dictionary(uniqueKeysWithValues:
                row.sorted { $0.value > $1.value }.prefix(Self.rowCap).map { ($0.key, $0.value) })
        }
        hits[py] = row

        if last[py] == word {
            let s = (streak[py] ?? 1) + 1
            streak[py] = s
            if s >= Self.autoPinStreak, pins[py] == nil { pins[py] = word }
        } else {
            last[py] = word
            streak[py] = 1
        }
        trimIfNeeded()
        markDirty()
        persistSoon()
    }

    /// 合并层加分：同拼音下选中越多的词越靠前。
    /// 用对数刻度（1.0 / 1.7 / 2.2 …）—— 第一次选就该见效，
    /// 连选十次也不至于把正确候选永久压死（线性加分的老毛病）。
    func boost(pinyin: String, word: String) -> Double {
        let py = Self.norm(pinyin)
        guard let c = hits[py]?[word], c > 0 else { return 0 }
        return 1.0 + log2(Double(c) + 1.0) * 0.9
    }

    /// 该拼音下用户选过的词（合并层补候选用，防止引擎把用户词漏掉）
    func userWords(pinyin: String) -> [String] {
        let py = Self.norm(pinyin)
        guard let row = hits[py] else { return [] }
        return row.sorted { $0.value > $1.value }.map { $0.key }
    }

    /// 联想种子：上屏句子里取末尾「词」而不是末尾「字」——
    /// 对标 `ipt_keyword_get_sentence_keyword`（按句内关键词联想）。
    /// 中文没有空格，这里用「末 2~4 字」当关键词近似，交给 bigram 表去命中。
    func lianSeeds(_ committed: String) -> [String] {
        let chars = Array(committed)
        guard chars.count > 1 else { return [] }
        var out: [String] = []
        for n in 2...4 where chars.count >= n {
            out.append(String(chars.suffix(n)))
        }
        return out
    }

    func clear() {
        hits.removeAll()
        pins.removeAll()
        last.removeAll()
        streak.removeAll()
        markDirty()
        persist()
    }

    // MARK: - 内部

    private static func norm(_ s: String) -> String {
        String(s.lowercased().filter { $0 >= "a" && $0 <= "z" })
    }

    /// 整体限规模：超出就把总选中次数最少的拼音串扔掉（键盘内存红线）
    private func trimIfNeeded() {
        guard hits.count > Self.keyCap else { return }
        let keep = hits
            .sorted { a, b in
                a.value.values.reduce(0, +) > b.value.values.reduce(0, +)
            }
            .prefix(Self.keyCap * 3 / 4)
            .map { $0.key }
        let keepSet = Set(keep)
        hits = hits.filter { keepSet.contains($0.key) }
        pins = pins.filter { keepSet.contains($0.key) }
        last = last.filter { keepSet.contains($0.key) }
        streak = streak.filter { keepSet.contains($0.key) }
    }

    private func markDirty() { dirty = true }

    /// 落盘节流：每 4 次记录写一次，避免每次上屏都打盘（扩展里 IO 很贵）
    private func persistSoon() {
        saveTick += 1
        if saveTick % 4 == 0 { persist() }
    }

    private struct Store: Codable {
        var hits: [String: [String: Int]]
        var pins: [String: String]
    }

    /// 落盘走后台串行队列：JSON 编码 + 写文件在扩展里都是真 IO，
    /// 卡在按键/上屏的主线程上就是掉帧甚至被 watchdog 打断。
    private let ioQueue = DispatchQueue(label: "anran.plumlite.io", qos: .utility)

    private func persist() {
        guard dirty else { return }
        dirty = false
        let snapshot = Store(hits: hits, pins: pins)   // 值类型，跨线程安全
        ioQueue.async {
            guard let d = try? JSONEncoder().encode(snapshot) else { return }
            SharedStore.write("ime_plumlite.json", d)
        }
    }

    private func load() {
        guard let d = SharedStore.read("ime_plumlite.json"),
              let s = try? JSONDecoder().decode(Store.self, from: d) else { return }
        hits = s.hits
        pins = s.pins
    }
}
