import Foundation

/// 词库资源保险柜：自建词库（pinyin.bin / assoc.bin）在仓库与 ipa 里都是密文，
/// 键盘要用时才解出来落临时文件，内存映射一建立就删盘 —— 解包的人拿到的是
/// 一坨 XOR 密文，明文只在运行瞬间的沙盒临时目录里存在过。
enum SecVault {

    /// 16 字节流密钥，仓库里存的是二次掩码（每个字节再 ^ 0x5A）
    private static let masked: [UInt8] = [
        0xED, 0xB8, 0x1B, 0xC6, 0x07, 0x59, 0xD5, 0x2C,
        0x40, 0x9E, 0x72, 0xC1, 0xAA, 0x3F, 0x88, 0x14
    ]
    private static let magic = Data("ANEX".utf8)

    private static let key: [UInt8] = masked.map { $0 ^ 0x5A }

    static func decrypt(_ data: Data) -> Data? {
        guard data.prefix(4) == magic, data.count > 4 else { return nil }
        var out = data.subdata(in: 4..<data.count)
        let k = key
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<p.count {
                p[i] ^= k[i & 15]
            }
        }
        return out
    }

    /// bundle 里找 `name.ext.enc` 解到临时文件；找不到密文就退回明文
    /// `name.ext`（本地调试 / 旧包兼容）。返回临时文件路径或明文原路径。
    static func stage(_ name: String, ext: String) -> URL? {
        let want = "\(name).\(ext).enc"
        let bundles = [Bundle(for: SecVault.self), Bundle.main]
        for b in bundles {
            for u in (b.urls(forResourcesWithExtension: "enc", subdirectory: nil) ?? []) {
                guard u.lastPathComponent == want,
                      let raw = try? Data(contentsOf: u),
                      let plain = decrypt(raw) else { continue }
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sv_\(UUID().uuidString).\(ext)")
                do {
                    try plain.write(to: out, options: .atomic)
                } catch {
                    return nil
                }
                return out
            }
        }
        for b in bundles {
            if let u = b.url(forResource: name, withExtension: ext) {
                return u
            }
        }
        return nil
    }

    /// 映射建立后删盘（POSIX 上删掉后已映射的内存页照样有效）。
    /// 只删临时目录里的，明文兜底的原件不动。
    static func dispose(_ url: URL?) {
        guard let url,
              url.path.hasPrefix(NSTemporaryDirectory()) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
