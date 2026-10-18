import Foundation
import Security

/// 服务端接口客户端
///
/// 跟电脑端同一套账号体系：登录换票据，心跳续票据。
/// 服务端用的是自签证书，这里做证书固定 —— 只认打包进来的 server.crt，
/// 别的一律拒绝，这样即使证书链不被系统信任也能安全通信。
final class AnRanAPI: NSObject {

    static let shared = AnRanAPI()

    /// 跟电脑端后台管理器同一个地址
    let baseURL = URL(string: "https://47.76.120.53")!

    struct LoginResult {
        var ok: Bool
        var error: String
        var ticket: String
        var expireAt: Int
        var boundNew: Bool
        var logoutSeq: Int?
    }

    struct HeartbeatResult {
        var ok: Bool
        var error: String
        var ticket: String
        var expireAt: Int
        var logoutSeq: Int?
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - 接口

    func login(username: String, password: String, machine: String,
               completion: @escaping (LoginResult) -> Void) {
        let body: [String: Any] = [
            "username": username,
            "password": password,
            "machine": machine,
            "platform": "ios",
        ]
        post("/api/login", body) { obj in
            completion(LoginResult(
                ok: (obj["ok"] as? Bool) ?? false,
                error: (obj["error"] as? String) ?? "",
                ticket: (obj["ticket"] as? String) ?? "",
                expireAt: (obj["expire_at"] as? NSNumber)?.intValue ?? 0,
                boundNew: (obj["bound_new"] as? Bool) ?? false,
                logoutSeq: (obj["logout_seq"] as? NSNumber)?.intValue))
        }
    }

    func heartbeat(ticket: String, machine: String,
                   completion: @escaping (HeartbeatResult) -> Void) {
        post("/api/heartbeat", ["ticket": ticket, "machine": machine]) { obj in
            completion(HeartbeatResult(
                ok: (obj["ok"] as? Bool) ?? false,
                error: (obj["error"] as? String) ?? "",
                ticket: (obj["ticket"] as? String) ?? "",
                expireAt: (obj["expire_at"] as? NSNumber)?.intValue ?? 0,
                logoutSeq: (obj["logout_seq"] as? NSNumber)?.intValue))
        }
    }

    /// 主App退登：服务端给这个账号的登出序号 +1，
    /// 所有还活着的票据（键盘等）下一跳心跳就对不上号，全部锁死
    func logout(ticket: String, completion: @escaping (Bool) -> Void) {
        post("/api/logout", ["ticket": ticket]) { obj in
            completion((obj["ok"] as? Bool) ?? false)
        }
    }

    /// 用户配置快照上报（思想库/自定义短语/手机号 JSON）：multipart file 字段。
    /// 实测服务端只认 X-Ticket 头做鉴权（X-Auth-Ticket/Cookie/表单字段全被 401 挡）。
    func uploadSnapshot(ticket: String, json: String,
                        completion: @escaping (Bool) -> Void) {
        let boundary = "anran." + UUID().uuidString
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/snapshot"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.setValue(ticket, forHTTPHeaderField: "X-Ticket")
        req.setValue("anran_ticket=\(ticket)", forHTTPHeaderField: "Cookie")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"ticket\"\r\n\r\n".data(using: .utf8)!)
        body.append(ticket.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"snapshot.json\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(json.data(using: .utf8)!)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        session.dataTask(with: req) { data, resp, _ in
            var ok = false
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (obj["ok"] as? Bool) ?? false
            }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                ok = false
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    // MARK: - 配置同步连接器

    /// 主App：查本账号是否已有键盘配对过（决定「同步数据」走静默推送还是出配对码）
    func pairStatus(ticket: String,
                    completion: @escaping (_ paired: Bool) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/pair/status"))
        req.httpMethod = "GET"
        req.setValue(ticket, forHTTPHeaderField: "X-Ticket")
        session.dataTask(with: req) { data, resp, _ in
            var paired = false
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                paired = (obj["paired"] as? Bool) ?? false
            }
            DispatchQueue.main.async { completion(paired) }
        }.resume()
    }

    /// 主App：登记一个6位配对码（键盘输这个码来领登录态），10分钟有效
    func pairStart(ticket: String, code: String,
                   completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/pair/start"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ticket, forHTTPHeaderField: "X-Ticket")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code])
        session.dataTask(with: req) { data, resp, _ in
            var ok = false
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (obj["ok"] as? Bool) ?? false
            }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                ok = false
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    struct ClaimResult {
        var ok: Bool
        var error: String
        var username: String
        var machine: String
        var ticket: String
        var expireAt: Int
        var logoutSeq: Int?
    }

    /// 键盘：配对码换登录态（一次性 用掉即作废）
    func pairClaim(code: String, completion: @escaping (ClaimResult) -> Void) {
        post("/api/pair/claim", ["code": code]) { obj in
            completion(ClaimResult(
                ok: (obj["ok"] as? Bool) ?? false,
                error: (obj["error"] as? String) ?? "",
                username: (obj["username"] as? String) ?? "",
                machine: (obj["machine"] as? String) ?? "",
                ticket: (obj["ticket"] as? String) ?? "",
                expireAt: (obj["expire_at"] as? NSNumber)?.intValue ?? 0,
                logoutSeq: (obj["logout_seq"] as? NSNumber)?.intValue))
        }
    }

    /// 主App：推送全量配置包（布局+短语+设置+思想库+登录态）
    func pushSync(ticket: String, data: Data,
                  completion: ((Bool) -> Void)? = nil) {
        let boundary = "anran." + UUID().uuidString
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/sync"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.setValue(ticket, forHTTPHeaderField: "X-Ticket")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"bundle.json\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        session.dataTask(with: req) { data, resp, _ in
            var ok = false
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ok = (obj["ok"] as? Bool) ?? false
            }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                ok = false
            }
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
    }

    /// 键盘：拉取最新配置包（没有推送过时服务端回 404）
    func pullSync(ticket: String, completion: @escaping (Data?) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/sync"))
        req.httpMethod = "GET"
        req.setValue(ticket, forHTTPHeaderField: "X-Ticket")
        session.dataTask(with: req) { data, resp, _ in
            var payload: Data?
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                payload = data
            }
            DispatchQueue.main.async { completion(payload) }
        }.resume()
    }

    // MARK: - 请求

    private func post(_ path: String, _ body: [String: Any],
                      completion: @escaping ([String: Any]) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("AnRanIME/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: req) { data, _, _ in
            var obj: [String: Any] = [:]
            if let data,
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let dict = parsed as? [String: Any] {
                obj = dict
            }
            DispatchQueue.main.async { completion(obj) }
        }.resume()
    }
}

// MARK: - 证书固定

extension AnRanAPI: URLSessionDelegate {

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

    /// 只认打包进来的那张 server.crt
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