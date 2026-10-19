import Foundation

/// 主 app 与键盘扩展共用的数据层
///
/// 两边通过 App Group 共享容器读写同一份数据（词库 / 思想库 / 剪贴板 / 自定义短语）。
/// 但 App Groups 是付费开发者能力，免费 Apple ID 用不了，声明了反而会让自签失败，
/// 所以正式分发不带这个 entitlement —— 这里永远拿不到共享容器，退回本机沙盒。
/// 主 app 与键盘之间的配置/登录态交接走服务器 + 回环 TCP 秒同步（见 ConfigSync / LocalSyncLink）。
/// 将来若改用付费账号或巨魔商店专属包，把 entitlement 加回来即可自动生效。
enum SharedStore {

    static let groupID = "group.com.anran.ime"

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
