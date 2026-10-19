import Foundation
import Network

/// 同设备秒同步数据链路：主程序当回环 TCP server，键盘扩展直连拉整包。
///
/// 为什么不是 App Group / 剪贴板：
/// - App Group 容器在免费 Apple ID 自签 + 侧载（TrollStore/Sideloadly）环境
///   拿不到（见 SharedStore 注释），主 app 与键盘扩展各困各的沙盒；
/// - 命名剪贴板能传但膈应 —— 剪贴板是用户隐私敏感区，同步数据不该往里躺，
///   用户明确要求「不要走剪贴板」。
/// 回环 socket 是第三条路：只监听 127.0.0.1、不碰沙盒外存储、不需要任何
/// entitlement，loopback 连接也不弹本地网络权限横幅。
///
/// 协议（一行 JSON，\n 结尾，UTF-8）：
///   client → server: {"mid":"<DeviceID>"}     本机校验，防同设备误连
///   server → client: SyncBundle 的 JSON 整包  mid 不符直接断开不回包
///
/// 兜底链：server 没起（主 app 被杀 / 挂起不响应）→ 键盘照旧走服务器拉取，
/// 上层同步逻辑一行不改。
enum LocalSyncLink {

    /// 固定高位端口（未注册段 49152-65535），只绑 127.0.0.1。
    static let port: NWEndpoint.Port = 49317

    private static let linkQueue = DispatchQueue(
        label: "com.anran.ime.localsync", qos: .utility)
    private static var listener: NWListener?
    private static let lock = NSLock()

    // MARK: - 主 app 侧：server

    /// 起本地 server（幂等，重复调只起一个）。
    /// bundleProvider 在主 app 进程内被调，每次连接现组整包，永远最新。
    static func startServer(bundleProvider: @escaping () -> SyncBundle?) {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            l.newConnectionHandler = { conn in
                serve(conn, provider: bundleProvider)
            }
            l.start(queue: linkQueue)
            listener = l
        } catch {
            // 端口被占（极端：同设备别的 app 抢了 49317）——放弃本地快路，
            // 同步照旧走服务器，功能不受影响
        }
    }

    private static func serve(_ conn: NWConnection,
                              provider: @escaping () -> SyncBundle?) {
        conn.start(queue: linkQueue)
        readLine(conn) { line in
            guard let line,
                  let data = line.data(using: .utf8),
                  let req = try? JSONDecoder().decode(Handshake.self, from: data),
                  req.mid == DeviceID.current else {
                conn.cancel()
                return
            }
            guard let bundle = provider() else { conn.cancel(); return }
            var payload = ""
            if let d = try? JSONEncoder().encode(bundle),
               let s = String(data: d, encoding: .utf8) {
                payload = s
            }
            conn.send(content: Data((payload + "\n").utf8),
                      completion: NWConnection.SendCompletion
                          .contentProcessed({ _ in conn.cancel() }))
        }
    }

    // MARK: - 键盘侧：client

    /// 连本地 server 拉整包。连不上 / 超时 / 协议错 → nil，调用方回落服务器。
    static func fetchBundle(timeout: TimeInterval = 1.5,
                            completion: @escaping (SyncBundle?) -> Void) {
        let conn = NWConnection(
            to: .hostPort(host: "127.0.0.1", port: port), using: .tcp)
        let once = OnceGuard()
        conn.stateUpdateHandler = { (state: NWConnection.State) in
            switch state {
            case .ready:
                var hello = "{}"
                if let d = try? JSONEncoder().encode(
                        Handshake(mid: DeviceID.current)),
                   let s = String(data: d, encoding: .utf8) {
                    hello = s
                }
                conn.send(content: Data((hello + "\n").utf8),
                          completion: NWConnection.SendCompletion
                              .contentProcessed({ _ in
                    readLine(conn) { line in
                        guard let line,
                              let data = line.data(using: .utf8),
                              let bundle = try? JSONDecoder().decode(
                                  SyncBundle.self, from: data) else {
                            conn.cancel()
                            once.run { completion(nil) }
                            return
                        }
                        conn.cancel()
                        once.run { completion(bundle) }
                    }
                }))
            case .failed, .cancelled:
                once.run { completion(nil) }
            default:
                break
            }
        }
        conn.start(queue: linkQueue)
        // 总超时：主 app 被挂起时 accept 不会来，别把调用方吊死
        linkQueue.asyncAfter(deadline: .now() + timeout) {
            conn.cancel()
            once.run { completion(nil) }
        }
    }

    // MARK: - 行协议

    /// 从连接读一行（累积到 \n 为止）。EOF/出错时把已收到的残buf当一行交回。
    private static func readLine(_ conn: NWConnection,
                                 completion: @escaping (String?) -> Void) {
        var buf = Data()
        func step() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, err in
                if let data, !data.isEmpty { buf.append(data) }
                if let r = buf.firstIndex(of: 0x0A) {
                    completion(String(data: buf.subdata(in: 0..<r), encoding: .utf8))
                    return
                }
                if isComplete || err != nil {
                    completion(buf.isEmpty ? nil : String(data: buf, encoding: .utf8))
                    return
                }
                step()
            }
        }
        step()
    }
}

/// 握手：本机设备标识。主 app 校验 == 本机 DeviceID 才回包，
/// 防同设备其他 app 误连（环回端口虽只在本机，协议层再拦一道）。
private struct Handshake: Codable {
    var mid: String
}

/// 保证 completion 只回调一次（state 失败 + 超时 + 读行三条路都可能到）。
private final class OnceGuard {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
