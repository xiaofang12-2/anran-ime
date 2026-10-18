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

/// 短语本（带版本戳，交接逻辑跟 KBConfig 一样，见 ConfigSync）
struct PhraseBook: Codable, Equatable {
    var items: [Phrase] = []
    var rev: Int = 0

    static let fallback = PhraseBook()

    /// 只去掉空码/空内容 同一个触发码允许多条（以前是后写的覆盖先写的 现在都保留）
    var sanitized: PhraseBook {
        var out: [Phrase] = []
        for p in items {
            var p = p
            p.position = max(1, p.position)
            guard !p.cleanCode.isEmpty, !p.text.isEmpty else { continue }
            out.append(p)
        }
        var b = self
        b.items = out
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
