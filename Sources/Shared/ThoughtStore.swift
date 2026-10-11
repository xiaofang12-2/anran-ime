import Foundation
import UIKit

/// 思想库的一条：关键词 -> 内容。
/// 键盘里输入关键词，就把对应内容上屏（对标电脑端「思想库」）。
struct ThoughtItem: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var keyword: String = ""
    var content: String = ""

    var cleanKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// 一个思想库（一本「书」），有名字，里面装若干关键词。
struct ThoughtLibrary: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String = ""
    var items: [ThoughtItem] = []
}

/// 思想库集合。与「键盘布局」「自定义短语」一样走剪贴板交接（见 ConfigSync）。
struct ThoughtBook: Codable, Equatable {
    var libraries: [ThoughtLibrary] = []
    /// 当前「使用中」的思想库。键盘只认这一本；为空时全部库都参与检索。
    /// 列表左滑点「使用」就切到这本（对标电脑端思想库的选中态）。
    var activeID: String? = nil
    var rev: Int = 0

    static let fallback = ThoughtBook()

    /// 去掉空名库、空关键词/空内容条目
    var sanitized: ThoughtBook {
        var b = self
        b.libraries = libraries
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { lib in
                var l = lib
                l.items = lib.items.filter {
                    !$0.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && !$0.content.isEmpty
                }
                return l
            }
        if let id = b.activeID, !b.libraries.contains(where: { $0.id == id }) {
            b.activeID = nil
        }
        return b
    }

    /// 扁平化：所有库的关键词拉平成一张表，键盘里按关键词检索用
    var flatItems: [ThoughtItem] {
        libraries.flatMap { $0.items }
    }

    /// 键盘检索用的条目：有「使用中」的库就只取那本，否则全部库都算
    var activeItems: [ThoughtItem] {
        if let id = activeID, let lib = libraries.first(where: { $0.id == id }) {
            return lib.items
        }
        return flatItems
    }
}

enum ThoughtStore {

    private static let key = "anran_kb_thoughts"

    static var current: ThoughtBook {
        guard let d = UserDefaults.standard.data(forKey: key),
              let b = try? JSONDecoder().decode(ThoughtBook.self, from: d) else {
            return ThoughtBook.fallback
        }
        return b.sanitized
    }

    static func saveLocal(_ b: ThoughtBook) {
        if let d = try? JSONEncoder().encode(b.sanitized) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
