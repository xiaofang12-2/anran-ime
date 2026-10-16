import Foundation

/// 用户配置快照上报：把思想库 + 自定义短语打包 POST 给服务端，
/// 管理端（黯然后台管理 App）按账号查看。
/// 上报内容做一次哈希去重 —— 没变化不打扰服务器。
enum SnapshotReport {

    private static let hashKey = "anran_snap_report_hash"
    private static var inflight = false

    static func uploadIfNeeded() {
        guard !inflight, AuthStore.isLoggedIn, let auth = AuthStore.current else { return }
        let pe = PhoneStore.entry(for: auth.username)
        let payload: [String: Any] = [
            "username": auth.username,
            "machine": auth.machine,
            "reported_at": Int(Date().timeIntervalSince1970),
            "phone": pe?.phone ?? "",
            "phone_at": pe?.savedAt ?? 0,
            "thoughts": encode(ThoughtStore.current),
            "phrases": encode(PhraseStore.current.items),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }

        var h: UInt32 = 5381
        for s in json.unicodeScalars {
            h = (h << 5 &+ s.value &+ h) & 0x7FFFFFFF
        }
        let hash = String(h)
        let last = UserDefaults.standard.string(forKey: hashKey)
        guard hash != last else { return }

        inflight = true
        AnRanAPI.shared.uploadSnapshot(ticket: auth.ticket, json: json) { ok in
            inflight = false
            if ok {
                UserDefaults.standard.set(hash, forKey: hashKey)
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        return obj
    }
}
