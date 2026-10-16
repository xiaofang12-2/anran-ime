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
    }

    struct HeartbeatResult {
        var ok: Bool
        var error: String
        var ticket: String
        var expireAt: Int
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
                boundNew: (obj["bound_new"] as? Bool) ?? false))
        }
    }

    func heartbeat(ticket: String, machine: String,
                   completion: @escaping (HeartbeatResult) -> Void) {
        post("/api/heartbeat", ["ticket": ticket, "machine": machine]) { obj in
            completion(HeartbeatResult(
                ok: (obj["ok"] as? Bool) ?? false,
                error: (obj["error"] as? String) ?? "",
                ticket: (obj["ticket"] as? String) ?? "",
                expireAt: (obj["expire_at"] as? NSNumber)?.intValue ?? 0))
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