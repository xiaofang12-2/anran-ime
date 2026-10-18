import Foundation

/// 一条自定义短语：打 code（拼音/字母串）就出 text
struct Phrase: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// 触发码，例如 dz / sfz / 地址。同一个码可以配多条 依次排在候选栏
    var code: String = ""
    /// 展开内容 支持多行 一行一句 发出去就是多行内容
    var text: String = ""
    /// 多行内容的起始候选位（1 起）：第1行排这个位 第2行往后依次+1
    /// （kz 五行 位置1 → 候选第1~5位）同一个码配多块时用位置错开
    var position: Int = 1

    var cleanCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 一组自定义短语：跟思想库一个用法 —— 先建一个「自定义名」
/// 点进去里面才是设置短语的地方。各组都生效（引擎拍平全量吃）。
struct PhraseGroup: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var items: [Phrase] = []
}

/// 短语本（带版本戳，交接逻辑跟 KBConfig 一样，见 ConfigSync）。
/// 兼容老数据：旧格式顶层是 items 数组，解码时自动收成一组「我的短语」。
struct PhraseBook: Codable, Equatable {
    var groups: [PhraseGroup] = []
    var rev: Int = 0

    enum CodingKeys: String, CodingKey { case groups, items, rev }

    init(groups: [PhraseGroup] = []) {
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = (try? c.decode([PhraseGroup].self, forKey: .groups)) ?? []
        if groups.isEmpty,
           let legacy = try? c.decode([Phrase].self, forKey: .items),
           !legacy.isEmpty {
            groups = [PhraseGroup(name: "我的短语", items: legacy)]
        }
        rev = (try? c.decode(Int.self, forKey: .rev)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groups, forKey: .groups)
        try c.encode(rev, forKey: .rev)
    }

    static let fallback = PhraseBook()

    /// 引擎吃的扁平条目：所有组的短语拍平全量给键盘
    var items: [Phrase] { groups.flatMap { $0.items } }

    /// 只去掉空码/空内容 同一个触发码允许多条
    var sanitized: PhraseBook {
        var out: [PhraseGroup] = []
        for g in groups {
            var items: [Phrase] = []
            for p in g.items {
                var p = p
                p.position = max(1, p.position)
                guard !p.cleanCode.isEmpty, !p.text.isEmpty else { continue }
                items.append(p)
            }
            var g = g
            g.items = items
            out.append(g)
        }
        var b = self
        b.groups = out
        return b
    }
}

enum PhraseStore {

    private static let key = "anran_kb_phrases"

    static var current: PhraseBook {
        guard let d = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(PhraseBook.self, from: d) else {
            return PhraseBook.fallback
        }
        return b.sanitized
    }

    static func saveLocal(_ b: PhraseBook) {
        if let d = try? JSONEncoder().encode(b.sanitized) {
            UserDefaults.standard.set(d, forKey: key)
        }
        NotificationCenter.default.post(name: ConfigSync.localStoreChanged, object: nil)
    }
}
