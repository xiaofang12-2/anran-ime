import Foundation

/// 用户自填手机号（本机自报 不发短信验证）：登录后必须填一次，
/// 跟配置快照一起上报服务端，后台账号详情里按账号可见。换绑直接覆盖。
enum PhoneStore {

    struct Entry: Codable, Equatable {
        var username: String
        var phone: String
        var savedAt: Int
    }

    private static let fileName = "phone.json"

    static func entry(for username: String) -> Entry? {
        guard let data = SharedStore.read(fileName),
              let e = try? JSONDecoder().decode(Entry.self, from: data),
              e.username == username, !e.phone.isEmpty else { return nil }
        return e
    }

    static func phone(for username: String) -> String? {
        entry(for: username)?.phone
    }

    static func save(phone: String, for username: String) {
        let e = Entry(username: username,
                      phone: phone,
                      savedAt: Int(Date().timeIntervalSince1970))
        guard let data = try? JSONEncoder().encode(e) else { return }
        SharedStore.write(fileName, data)
    }

    /// 只做格式把关（11位 1开头 纯数字），防手滑填错
    static func isValid(_ p: String) -> Bool {
        p.count == 11 && p.hasPrefix("1") && p.allSatisfy { $0.isNumber }
    }
}
