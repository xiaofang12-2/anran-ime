import Foundation

/// 用户配置快照上报：把思想库 + 自定义短语打包 POST 给服务端，
/// 管理端（黯然后台管理 App）按账号查看。
/// 上报内容做一次哈希去重 —— 没变化不打扰服务器。
enum SnapshotReport {

    private static let hashKey = "anran_snap_report_hash"
    private static var inflight = false

    static func uploadIfNeeded() {
        guard !inflight, AuthStore.isLoggedIn, let auth = AuthStore.current else { return }
        let payload: [String: Any] = [
            "username": auth.username,
            "machine": auth.machine,
            "reported_at": Int(Date().timeIntervalSince1970),
            "thoughts": encode(ThoughtStore.current),
            "phrases": encode(PhraseStore.current.items),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }

        let hash = String(json.unicodeScalars.lazy.map { $0.value }.reduce(5381) {
            ($0 << 5 &+ $1 &+ $0) & 0x7FFFFFFF
        })
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
