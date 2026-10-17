import Foundation
import UIKit

/// 登录态
struct AuthState: Codable, Equatable {
    var username: String
    var ticket: String
    var machine: String
    var expireAt: Int      // 0 表示永久
    var savedAt: Int
}

/// 登录态存储
///
/// 优先写 App Group 共享容器，主 app 登录后键盘能直接读到。
/// 免费签名拿不到 App Groups 时，两边各自退回沙盒 —— 这时靠「剪贴板交接」：
/// 主 app 里点一下「同步到键盘」，把票据塞进剪贴板；键盘开完全访问后
/// 读一次剪贴板把票据接过去，之后就一直用自己存的那份。
enum AuthStore {

    private static let fileName = "auth.json"
    private static let pastePrefix = "ANRAN-AUTH::"

    static var current: AuthState? {
        guard let data = SharedStore.read(fileName) else { return nil }
        return try? JSONDecoder().decode(AuthState.self, from: data)
    }

    static var isLoggedIn: Bool {
        guard let s = current, !s.ticket.isEmpty else { return false }
        return !expired(s)
    }

    static func expired(_ s: AuthState) -> Bool {
        s.expireAt != 0 && s.expireAt <= Int(Date().timeIntervalSince1970)
    }

    @discardableResult
    static func save(username: String, ticket: String,
                     expireAt: Int) -> AuthState {
        let state = AuthState(username: username,
                              ticket: ticket,
                              machine: DeviceID.current,
                              expireAt: expireAt,
                              savedAt: Int(Date().timeIntervalSince1970))
        write(state)
        return state
    }

    static func write(_ state: AuthState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        SharedStore.write(fileName, data)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: SharedStore.url(fileName))
    }

    // MARK: - 剪贴板交接

    /// 主 app 用：把当前登录态编码成一段文本放剪贴板。
    /// 走整包交接（ConfigSync）—— 登录态单独占剪贴板会把配置冲掉，并进同一个包最稳。
    @discardableResult
    static func exportToPasteboard() -> Bool {
        guard current != nil else { return false }
        return ConfigSync.publish()
    }

    /// 键盘用：剪贴板里若有一段票据就接过来存下（接不到返回 false）
    @discardableResult
    static func importFromPasteboard() -> Bool {
        guard let raw = UIPasteboard.general.string,
              raw.hasPrefix(pastePrefix) else { return false }
        let json = String(raw.dropFirst(pastePrefix.count))
        guard let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(AuthState.self, from: data),
              !state.ticket.isEmpty else { return false }
        // 票据里的设备号必须就是本机，防止把别的机器的票据搬过来
        guard state.machine == DeviceID.current else { return false }
        write(state)
        UIPasteboard.general.string = ""
        return true
    }
}