import Foundation

/// 一条自定义短语：打 code（拼音/字母串）就出 text
struct Phrase: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    /// 触发码，例如 dz / sfz / 地址
    var code: String = ""
    /// 展开内容，例如 张三 13800000000 北京市朝阳区
    var text: String = ""
    /// 命中后排在候选第几位（1 起）。1 = 排到第一位
    /// 对标电脑端百度/搜狗的自定义短语「位置」
    var position: Int = 1

    var cleanCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 短语本（带版本戳，交接逻辑跟 KBConfig 一样，见 ConfigSync）
struct PhraseBook: Codable, Equatable {
    var items: [Phrase] = []
    var rev: Int = 0

    static let fallback = PhraseBook()

    /// 去掉空码/空内容与重复触发码，后写的覆盖先写的
    var sanitized: PhraseBook {
        var seen = Set<String>()
        var out: [Phrase] = []
        for p in items.reversed() {
            var p = p
            p.position = max(1, p.position)
            let c = p.cleanCode
            guard !c.isEmpty, !p.text.isEmpty, !seen.contains(c) else { continue }
            seen.insert(c)
            out.append(p)
        }
        var b = self
        b.items = out.reversed()
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
