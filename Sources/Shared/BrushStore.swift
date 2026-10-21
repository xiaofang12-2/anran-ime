import Foundation
import UIKit

/// 刷天帝的一条文本：名称 + 内容（不限任何内容，按行拆）。
/// 键盘里选中文本，点开启就自动逐行输出（比思想库更快）。
struct BrushItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var content: String = ""
}

/// 刷天帝文本集合（扁平，不需要「库」的二级结构）
struct BrushBook: Codable, Equatable {
    var items: [BrushItem] = []
    var rev: Int = 0

    static let fallback = BrushBook()

    /// 去掉空名 / 空内容条目
    var sanitized: BrushBook {
        var b = self
        b.items = items.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.content.isEmpty
        }
        return b
    }
}

/// 刷天帝存储层 —— 与思想库同构，走 UserDefaults + ConfigSync 整包同步。
enum BrushStore {

    private static let key = "anran_kb_brush"

    static var current: BrushBook {
        guard let d = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(BrushBook.self, from: d) else {
            return BrushBook.fallback
        }
        return b.sanitized
    }

    static func saveLocal(_ b: BrushBook) {
        if let d = try? JSONEncoder().encode(b.sanitized) {
            UserDefaults.standard.set(d, forKey: key)
        }
        NotificationCenter.default.post(name: ConfigSync.localStoreChanged, object: nil)
    }
}
