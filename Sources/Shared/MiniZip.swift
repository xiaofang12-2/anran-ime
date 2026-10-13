import Foundation
import Compression

/// 极简 zip 读取器：皮肤文件（百度 .bdi / 通用 .zip）本质上就是 zip 包，
/// iOS 系统不给公开的解压 API，第三方库又要拉网络，干脆自己写一个。
/// 只支持读：store(0) 与 deflate(8)，足够 skin 这类资源包用。
enum MiniZipError: Error {
    case notZip          // 头都不对，压根不是 zip（可能是加密皮肤或别的格式）
    case corrupt         // 结构坏/截断
}

struct MiniZip {

    private let data: Data

    init(_ data: Data) throws {
        self.data = data
        guard data.count > 22, Self.u32(data, 0) == 0x04034B50 || Self.findEOCD(data).offset >= 0 else {
            throw MiniZipError.notZip
        }
        guard Self.findEOCD(data).offset >= 0 else { throw MiniZipError.corrupt }
    }

    /// 解包全部条目：文件名 → 内容（目录条目与空文件跳过）
    func unzipAll() -> [String: Data] {
        var out: [String: Data] = [:]
        let eocd = Self.findEOCD(data)
        guard eocd.offset >= 0 else { return out }
        let total = Int(eocd.entries)
        var p = Int(eocd.cdOffset)
        let base = data.startIndex
        for _ in 0..<total {
            guard p + 46 <= data.count, Self.u32(data, p) == 0x02014B50 else { break }
            let method = Self.u16(data, p + 10)
            let compSize = Int(Self.u32(data, p + 20))
            let nameLen = Int(Self.u16(data, p + 28))
            let extraLen = Int(Self.u16(data, p + 30))
            let commentLen = Int(Self.u16(data, p + 32))
            let localOff = Int(Self.u32(data, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLen <= data.count else { break }
            let name = String(data: data.subdata(in: base + nameStart..<base + nameStart + nameLen),
                              encoding: .utf8) ?? ""
            p = nameStart + nameLen + extraLen + commentLen

            guard !name.hasSuffix("/"), compSize > 0, localOff + 30 <= data.count,
                  Self.u32(data, localOff) == 0x04034B50 else { continue }
            let lNameLen = Int(Self.u16(data, localOff + 26))
            let lExtraLen = Int(Self.u16(data, localOff + 28))
            let dataStart = localOff + 30 + lNameLen + lExtraLen
            guard dataStart + compSize <= data.count else { continue }
            let raw = data.subdata(in: base + dataStart..<base + dataStart + compSize)
            switch method {
            case 0:
                out[name] = raw
            case 8:
                if let d = Self.inflate(raw) { out[name] = d }
            default:
                break
            }
        }
        return out
    }

    // MARK: - deflate 解压（zip 里的 zlib 是 raw deflate，不带 zlib 头）

    private static func inflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        var dstCap = max(input.count * 8, 64 * 1024)
        var dst = Data(count: dstCap)
        var dstSize = 0
        var retries = 0
        while retries < 6 {
            let r = dst.withUnsafeMutableBytes { db -> Int in
                input.withUnsafeBytes { sb in
                    guard let dp = db.bindMemory(to: UInt8.self).baseAddress,
                          let sp = sb.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dp, dstCap, sp, input.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            // 返回值 == 0 可能是缓冲区不够，扩一倍再试
            if r > 0 || input.count == 0 { dstSize = r; break }
            dstCap *= 2
            dst = Data(count: dstCap)
            retries += 1
        }
        guard dstSize > 0 else { return nil }
        return dst.prefix(dstSize)
    }

    // MARK: - EOCD / 小端读取

    private static func findEOCD(_ d: Data) -> (offset: Int, entries: UInt16, cdOffset: UInt32) {
        // EOCD 最少 22 字节，注释最长 65536，从尾部往前扫签名
        let lo = max(0, d.count - 22 - 65536)
        var i = d.count - 22
        while i >= lo {
            if u32(d, i) == 0x06054B50 {
                let entries = u16(d, i + 10)
                let cdOff = u32(d, i + 16)
                return (i, entries, cdOff)
            }
            i -= 1
        }
        return (-1, 0, 0)
    }

    private static func u16(_ d: Data, _ off: Int) -> UInt16 {
        guard off + 2 <= d.count else { return 0 }
        return UInt16(d[d.startIndex + off]) | (UInt16(d[d.startIndex + off + 1]) << 8)
    }

    private static func u32(_ d: Data, _ off: Int) -> UInt32 {
        guard off + 4 <= d.count else { return 0 }
        return UInt32(d[d.startIndex + off])
            | (UInt32(d[d.startIndex + off + 1]) << 8)
            | (UInt32(d[d.startIndex + off + 2]) << 16)
            | (UInt32(d[d.startIndex + off + 3]) << 24)
    }
}
