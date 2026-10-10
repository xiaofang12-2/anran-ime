import Foundation
import UIKit

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
    static let pastePrefix = "ANRAN-PHRASE::"

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
    }

    /// 主程序用：存本机 + 塞剪贴板
    @discardableResult
    static func publish(_ b: PhraseBook) -> Bool {
        var n = b.sanitized
        n.rev = Int(Date().timeIntervalSince1970)
        saveLocal(n)
        guard let d = try? JSONEncoder().encode(n),
              let s = String(data: d, encoding: .utf8) else { return false }
        UIPasteboard.general.string = PhraseBook.pastePrefix + s
        return true
    }

    /// 键盘用：剪贴板里有更新的短语本才接
    @discardableResult
    static func pullFromPasteboard() -> Bool {
        guard let raw = UIPasteboard.general.string,
              raw.hasPrefix(PhraseBook.pastePrefix) else { return false }
        let json = String(raw.dropFirst(PhraseBook.pastePrefix.count))
        guard let d = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(PhraseBook.self, from: d)
        else { return false }
        guard incoming.rev > current.rev else { return false }
        saveLocal(incoming)
        return true
    }
}
