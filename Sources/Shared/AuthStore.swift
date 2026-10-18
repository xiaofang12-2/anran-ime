import Foundation

/// 登录态
struct AuthState: Codable, Equatable {
    var username: String
    var ticket: String
    var machine: String
    var expireAt: Int      // 0 表示永久
    var savedAt: Int
    /// 账号级登出序号：服务端 /api/logout 每次退登 +1。
    /// 心跳带回来的对不上 = 这个账号在别处退登过，旧票据全部作废。
    /// 可选：老票据没这字段也能照常解码。
    var logoutSeq: Int?
}

/// 登录态存储
///
/// 主程序登录拿票；键盘第一次凭「配对码」从服务器领票（见 ConfigSync），
/// 之后心跳自动续票。两边各自落自己沙盒的 auth.json，互不干扰。
enum AuthStore {

    private static let fileName = "auth.json"

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
                     expireAt: Int, logoutSeq: Int? = nil) -> AuthState {
        let state = AuthState(username: username,
                              ticket: ticket,
                              machine: DeviceID.current,
                              expireAt: expireAt,
                              savedAt: Int(Date().timeIntervalSince1970),
                              logoutSeq: logoutSeq)
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
}
