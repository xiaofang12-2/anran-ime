import Foundation

/// 主 app 与键盘扩展共用的数据层
///
/// 两边通过 App Group 共享容器读写同一份数据（词库 / 思想库 / 剪贴板 / 自定义短语）。
/// 注意：免费 Apple ID 属于 Personal Team，App Groups 能不能用需要真机实测 ——
/// 拿不到共享容器时这里退回本机沙盒，保证不崩，主 app 的自检卡片会报出来。
enum SharedStore {

    static let groupID = "group.com.anran.ime"

    /// 共享容器是否真的可用（不是退回沙盒）
    static var isGroupAvailable: Bool {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }

    /// 数据根目录：优先共享容器，拿不到就退回本 app 沙盒
    static var rootURL: URL {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return url
        }
        return FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func url(_ name: String) -> URL {
        rootURL.appendingPathComponent(name)
    }

    /// 确保某个子目录存在并返回它
    @discardableResult
    static func ensureDir(_ name: String) -> URL {
        let url = self.url(name)
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    static func read(_ name: String) -> Data? {
        try? Data(contentsOf: url(name))
    }

    @discardableResult
    static func write(_ name: String, _ data: Data) -> Bool {
        do {
            try data.write(to: url(name), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
