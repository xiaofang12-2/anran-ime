import Foundation
import CryptoKit

/// 词库资源保险柜：自建词库（pinyin.bin / assoc.bin）在仓库与 ipa 里都是
/// AES-256-GCM 密文（ANAX：magic + 12字节nonce + 密文+tag）。
/// 密钥在二进制里不存明文 —— 拆成三段分片各存一份，运行时异或拼装。
/// 键盘要用时才解出来落临时文件，内存映射一建立就删盘 —— 解包的人拿到的是
/// 一坨 AES 密文，明文只在运行瞬间的沙盒临时目录里存在过。
enum SecVault {

    private static let k1: [UInt8] = [
        0x5A, 0xD0, 0xD9, 0x76, 0xCC, 0x16, 0xE8, 0x7C,
        0x9B, 0x1F, 0xAF, 0x8E, 0x11, 0x3F, 0x1E, 0x47,
        0x2C, 0x77, 0x34, 0x46, 0x75, 0x55, 0x44, 0x74,
        0x33, 0x72, 0x5F, 0x7D, 0xA9, 0xFC, 0x0E, 0xC9
    ]
    private static let k2: [UInt8] = [
        0xB4, 0x66, 0x48, 0x72, 0x02, 0xE3, 0x0B, 0xD9,
        0x0F, 0x91, 0x1E, 0x4D, 0xD4, 0x89, 0x29, 0x32,
        0xA6, 0xAD, 0xAE, 0xFA, 0x92, 0x88, 0x4F, 0xA3,
        0x59, 0xF1, 0x25, 0x4F, 0x9D, 0x13, 0xCD, 0xC2
    ]
    private static let k3: [UInt8] = [
        0x7F, 0x4C, 0xB8, 0x73, 0xDA, 0x11, 0xB3, 0xDC,
        0xC2, 0xE6, 0xB1, 0x0D, 0xCC, 0xB9, 0x29, 0xF7,
        0x67, 0xC9, 0xD2, 0xD2, 0xC9, 0x5C, 0xD1, 0xC3,
        0x7B, 0x5E, 0xF0, 0xDD, 0xFB, 0x8B, 0x4A, 0x90
    ]
    private static let magic = Data("ANAX".utf8)

    private static let key: SymmetricKey = {
        var merged = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { merged[i] = k1[i] ^ k2[i] ^ k3[i] }
        return SymmetricKey(data: Data(merged))
    }()

    /// 定位本代码所在 bundle（主程序 / 键盘扩展各自的主包）
    private final class Token {}
    private static let owner = Bundle(for: Token.self)

    /// 评测/CI 用：设了 `ANRAN_DICT_DIR` 就直接读该目录下的明文 `name.ext`，
    /// 跳过解密。**只在命令行工具里生效**：iOS 进程拿不到这个环境变量，
    /// 线上包永远走下面的密文路径。
    private static var plainDir: URL? {
        guard let p = ProcessInfo.processInfo.environment["ANRAN_DICT_DIR"],
              !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static func decrypt(_ data: Data) -> Data? {
        guard data.prefix(4) == magic, data.count > 4 + 12 + 16 else { return nil }
        // 注意：这里**不能**用 data.subdata(in:) —— 那会再复制一份 27MB。
        // 用切片（共享底层 buffer）构造 SealedBox，峰值只多一份明文。
        let body = data.dropFirst(4)
        let nonceData = body.prefix(12)
        let rest = body.dropFirst(12)
        guard rest.count > 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce,
                                               ciphertext: rest.dropLast(16),
                                               tag: rest.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// bundle 里找 `name.ext.enc` 解到临时文件；找不到密文就退回明文
    /// `name.ext`（本地调试兼容）。返回临时文件路径或明文原路径。
    ///
    /// 两种密文格式都认：
    ///   ANX2（分块，推荐）—— 流式解密，峰值内存 = 一块（约 1MB），与词库大小无关
    ///   ANAX（整包，旧）  —— 只为兼容老包，27MB 词库走这里峰值仍有 50MB 级
    static func stage(_ name: String, ext: String) -> URL? {
        // 评测通道（见 plainDir 注释）
        if let dir = plainDir {
            let u = dir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        let want = "\(name).\(ext).enc"
        for u in (owner.urls(forResourcesWithExtension: "enc", subdirectory: nil)
                   ?? []) {
            guard u.lastPathComponent == want else { continue }
            if let out = stageChunked(u, ext: ext) { return out }
            // ANAX 旧格式兜底：先解出来，再立刻丢掉密文引用，最后才写盘
            if let raw = try? Data(contentsOf: u),
               let plain = decryptInto(raw) {
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sv_\(UUID().uuidString).\(ext)")
                // 不用 .atomic：atomic 会额外复制一份 27MB 到临时文件
                do {
                    try plain.write(to: out)
                    return out
                } catch {
                    return nil
                }
            }
        }
        if let u = owner.url(forResource: name, withExtension: ext) {
            return u
        }
        return nil
    }

    /// 读密文 -> 解出明文 -> 立刻释放密文（放在内层作用域），再返回明文
    private static func decryptInto(_ raw: Data) -> Data? {
        var plain: Data?
        autoreleasepool {
            plain = decrypt(raw)
        }
        return plain
    }

    /// ANX2 流式解密：逐块读、逐块解、逐块写。
    /// 布局：`ANX2` + u32 块大小 + u32 块数 + u32[块数] 各块密文长度 + 各块密文
    /// （每块 = nonce12 + 密文 + tag16）
    private static func stageChunked(_ url: URL, ext: String) -> URL? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        func le32(_ d: Data, _ o: Int) -> Int {
            guard o + 4 <= d.count else { return 0 }
            return Int(d[d.startIndex + o]) | (Int(d[d.startIndex + o + 1]) << 8)
                | (Int(d[d.startIndex + o + 2]) << 16) | (Int(d[d.startIndex + o + 3]) << 24)
        }

        guard let head = try? fh.read(upToCount: 12), head.count == 12,
              head.prefix(4) == Data("ANX2".utf8) else { return nil }
        let n = le32(head, 8)
        guard n > 0, n < 200_000,
              let tbl = try? fh.read(upToCount: 4 * n), tbl.count == 4 * n
        else { return nil }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("sv_\(UUID().uuidString).\(ext)")
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let oh = try? FileHandle(forWritingTo: out) else { return nil }

        var ok = true
        for i in 0..<n {
            let L = le32(tbl, 4 * i)
            guard L > 28, L < (32 << 20),
                  let seg = try? fh.read(upToCount: L), seg.count == L,
                  let nonce = try? AES.GCM.Nonce(data: seg.prefix(12)),
                  let box = try? AES.GCM.SealedBox(nonce: nonce,
                                                   ciphertext: seg.dropFirst(12).dropLast(16),
                                                   tag: seg.suffix(16)),
                  let plain = try? AES.GCM.open(box, using: key)
            else { ok = false; break }
            do { try oh.write(contentsOf: plain) } catch { ok = false; break }
        }
        try? oh.close()
        if !ok {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    /// 映射建立后删盘（POSIX 上删掉后已映射的内存页照样有效）。
    /// 只删临时目录里的，明文兜底的原件不动。
    static func dispose(_ url: URL?) {
        guard let url,
              url.path.hasPrefix(NSTemporaryDirectory()) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
