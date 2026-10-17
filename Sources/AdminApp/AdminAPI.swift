import Foundation
import Security

/// 后台管理 API 客户端（iOS 版管理器）
///
/// 与电脑端管理器同一个服务端：管理员密码登录拿 cookie 会话，
/// 之后所有 /admin/api/* 请求自动带 cookie。
/// 服务端自签证书 —— 证书固定只认包里的 server.crt。
final class AdminAPI: NSObject {

    static let shared = AdminAPI()

    let baseURL = URL(string: "https://47.76.120.53")!

    // MARK: - 数据模型

    struct Device {
        var platform: String
        var machine: String
        var lastSeen: Int
    }

    struct Account {
        var id: Int
        var username: String
        var expireAt: Int
        var disabled: Bool
        var note: String
        var lastLoginAt: Int
        var snapSize: Int
        var phone: String
        var phoneAt: Int
        var devices: [Device]
    }

    struct CreateResult {
        var ok: Bool
        var error: String
        var id: Int
        var password: String
    }

    // MARK: - 会话

    static var isLoggedIn: Bool {
        HTTPCookieStorage.shared.cookies?.contains {
            $0.name == "anran_admin" && $0.domain.contains("47.76.120.53")
        } == true
    }

    static func logout() {
        if let cookies = HTTPCookieStorage.shared.cookies {
            for c in cookies where c.domain.contains("47.76.120.53") {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
    }

    // MARK: - 接口

    func login(password: String, completion: @escaping (Bool, String) -> Void) {
        post("/admin/api/login", ["password": password]) { obj in
            completion((obj["ok"] as? Bool) ?? false,
                       (obj["error"] as? String) ?? "")
        }
    }

    func accounts(completion: @escaping ([Account]) -> Void) {
        // 服务端这个接口只认 GET，POST 会 405（列表空白的根因）
        var req = URLRequest(url: baseURL.appendingPathComponent("/admin/api/accounts"))
        req.httpMethod = "GET"
        session.dataTask(with: req) { data, resp, _ in
            var list: [Account] = []
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["accounts"] as? [[String: Any]] {
                for a in arr {
                    var devs: [Device] = []
                    if let ds = a["devices"] as? [[String: Any]] {
                        for d in ds {
                            devs.append(Device(
                                platform: (d["platform"] as? String) ?? "?",
                                machine: (d["machine"] as? String) ?? "",
                                lastSeen: (d["last_seen_at"] as? NSNumber)?.intValue ?? 0))
                        }
                    }
                    list.append(Account(
                        id: (a["id"] as? NSNumber)?.intValue ?? 0,
                        username: (a["username"] as? String) ?? "",
                        expireAt: (a["expire_at"] as? NSNumber)?.intValue ?? 0,
                        disabled: ((a["disabled"] as? NSNumber)?.intValue ?? 0) != 0,
                        note: (a["note"] as? String) ?? "",
                        lastLoginAt: (a["last_login_at"] as? NSNumber)?.intValue ?? 0,
                        snapSize: (a["snap_size"] as? NSNumber)?.intValue ?? 0,
                        phone: (a["phone"] as? String) ?? "",
                        phoneAt: (a["phone_at"] as? NSNumber)?.intValue ?? 0,
                        devices: devs))
                }
            }
            DispatchQueue.main.async { completion(list) }
        }.resume()
    }

    /// 建号：密码留空则服务端自动生成；days 为有效期天数（服务端不接受 0，
    /// 永久由调用方建完再 update expire_at=0）
    func create(username: String, note: String, password: String, days: Int,
                completion: @escaping (CreateResult) -> Void) {
        var body: [String: Any] = ["username": username, "days": days]
        if !note.isEmpty { body["note"] = note }
        if !password.isEmpty { body["password"] = password }
        post("/admin/api/account/create", body) { obj in
            completion(CreateResult(
                ok: (obj["ok"] as? Bool) ?? false,
                error: (obj["error"] as? String) ?? "",
                id: (obj["id"] as? NSNumber)?.intValue ?? 0,
                password: (obj["password"] as? String) ?? ""))
        }
    }

    /// 改号：禁用/启用、改到期（0=永久）、改备注、改手机号、改密码
    func update(accountId: Int, disabled: Bool? = nil, expireAt: Int? = nil,
                note: String? = nil, phone: String? = nil, password: String? = nil,
                completion: @escaping (Bool, String) -> Void) {
        var body: [String: Any] = ["account_id": accountId]
        if let disabled { body["disabled"] = disabled ? 1 : 0 }
        if let expireAt { body["expire_at"] = expireAt }
        if let note { body["note"] = note }
        if let phone { body["phone"] = phone }
        if let password, !password.isEmpty { body["password"] = password }
        post("/admin/api/account/update", body) { obj in
            completion((obj["ok"] as? Bool) ?? false, (obj["error"] as? String) ?? "")
        }
    }

    func delete(accountId: Int, completion: @escaping (Bool, String) -> Void) {
        post("/admin/api/account/delete", ["account_id": accountId]) { obj in
            completion((obj["ok"] as? Bool) ?? false, (obj["error"] as? String) ?? "")
        }
    }

    /// 解绑设备：machine 传 "all" 解全部
    func unbind(accountId: Int, machine: String,
                completion: @escaping (Bool, String) -> Void) {
        post("/admin/api/device/unbind", ["account_id": accountId, "machine": machine]) { obj in
            completion((obj["ok"] as? Bool) ?? false, (obj["error"] as? String) ?? "")
        }
    }

    /// 用户上报的快照原文（思想库/自定义短语 JSON）。
    /// 服务端返回 plain（明文）或 raw_b64（原样base64）——实测它解不了App的
    /// JSON格式时会走 raw_b64，内容本身就是明文JSON，解一层base64即可读。
    func snapshot(accountId: Int, completion: @escaping (Bool, String) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent(
            "/admin/api/account/snapshot?account_id=\(accountId)"))
        req.httpMethod = "GET"
        session.dataTask(with: req) { data, resp, _ in
            var ok = false
            var json = ""
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (obj["ok"] as? Bool) ?? false
                json = (obj["plain"] as? String) ?? ""
                if json.isEmpty,
                   let b64 = obj["raw_b64"] as? String,
                   let decoded = Data(base64Encoded: b64),
                   let s = String(data: decoded, encoding: .utf8) {
                    json = s
                }
            }
            if let http = resp as? HTTPURLResponse, http.statusCode == 401 { ok = false }
            DispatchQueue.main.async { completion(ok, json) }
        }.resume()
    }

    // MARK: - 请求

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private func post(_ path: String, _ body: [String: Any],
                      completion: @escaping ([String: Any]) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, resp, _ in
            var obj: [String: Any] = [:]
            if let data,
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let dict = parsed as? [String: Any] {
                obj = dict
            }
            if let http = resp as? HTTPURLResponse, http.statusCode == 401,
               obj["error"] == nil {
                obj["ok"] = false
                obj["error"] = "unauthorized"
            }
            DispatchQueue.main.async { completion(obj) }
        }.resume()
    }
}

// MARK: - 证书固定（与主 App 同一张 server.crt）

extension AdminAPI: URLSessionDelegate {

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod
                == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.matchesPinnedCert(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private static func matchesPinnedCert(_ trust: SecTrust) -> Bool {
        guard let pinned = pinnedCertDER() else { return false }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return false }
        return (SecCertificateCopyData(leaf) as Data) == pinned
    }

    private static var pinnedCache: Data?

    private static func pinnedCertDER() -> Data? {
        if let pinnedCache { return pinnedCache }
        guard let url = Bundle.main.url(forResource: "server", withExtension: "crt"),
              let pem = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let body = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: body) else { return nil }
        pinnedCache = data
        return data
    }
}
