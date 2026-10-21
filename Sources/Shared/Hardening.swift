import Foundation
import Darwin
import MachO
import CommonCrypto

/// 全端防护（主程序 + 键盘扩展启动各调一次 arm()）：
///   1. ptrace(PT_DENY_ATTACH) —— 调试器一挂上进程直接断开；
///   2. csops / sysctl / DYLD 环境变量巡检 —— **只上报，不自杀**；
///   3. 二进制完整性对账 —— **只上报，不自杀**；
///   4. SecStr 轻混淆 —— 关键字符串在二进制里不是明文。
///
/// ⚠️ 为什么不再自杀了（这是「键盘用一会儿突然消失、切回上一个输入法」的真因）：
///   本产品全靠自签安装（Sideloadly / TrollStore）。自签必然重签 → Mach-O 变了
///   → 完整性哈希必然和官方包不一致；Sideloadly 只要勾了「注入 tweak」，
///   扩展进程就自带 DYLD_INSERT_LIBRARIES。这两件事在自签场景下 100% 误报，
///   旧逻辑误报后随机 25~140 秒 exit(0)，用户看到的就是键盘突然没了、
///   iOS 自动切回上一个输入法 —— 而且「有时候才发生」，因为延迟是随机的。
///   安全上没有任何收益：能被逆的人早就把这段 NOP 掉了，被误杀的只有正常用户。
enum Hardening {

    private static var armed = false
    private static var reported = Set<String>()

    static func arm() {
        guard !armed else { return }
        armed = true
        denyAttach()
        if debuggerPresent() { report("debugger") }
        if debugFlagged() { report("latched") }
        if hostileLibraries() { report("hooklib") }
        if bundledInjectables() { report("bundledylib") }
        clearInjectionEnv()
        reportBinaryIntegrity()
    }

    /// 发现异常只上报一次，绝不退出进程。
    private static func report(_ kind: String) {
        guard reported.insert(kind).inserted else { return }
        AnRanAPI.shared.reportTamper(kind)
    }

    /// 蜜罐线索：假诊断接口 + 假万能钥匙 + 假root口令，专喂逆向工具的 strings 扫描，
    /// 谁拿去打服务器，服务器立刻记下完整 IP 和指纹然后全站封禁
    @inline(never)
    private static func canary() -> [String] {
        ["https://47.76.120.53/api/admin/__diag",
         "ANRAN-MASTER-KEY-v3-7742",
         "https://47.76.120.53/api/master/unlock",
         "https://47.76.120.53/api/pair/bypass",
         "ANRAN-ROOT-PASS-0x9F3A",
         "https://47.76.120.53/api/admin/master"]
    }

    /// ptrace(PT_DENY_ATTACH)：后续 attach 全被系统拒绝
    private static func denyAttach() {
        if let sym = dlsym(dlopen(nil, RTLD_LAZY), "ptrace") {
            typealias Fn = @convention(c)(Int32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
            let fn = unsafeBitCast(sym, to: Fn.self)
            _ = fn(31 /* PT_DENY_ATTACH */, 0, nil, 0)
        }
    }

    /// csops(CS_OPS_STATUS)：进程带 CS_DEBUGGED 标 = 启动时就挂着调试器
    private static func debugFlagged() -> Bool {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "csops") else { return false }
        typealias Fn = @convention(c)(Int32, UInt32, UnsafeMutableRawPointer, Int) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var flags: UInt32 = 0
        guard fn(getpid(), 0 /* CS_OPS_STATUS */, &flags,
                 MemoryLayout<UInt32>.size) == 0 else { return false }
        return flags & 0x1000_0000 /* CS_DEBUGGED */ != 0
    }

    /// sysctl 查 P_TRACED + 常见注入/调试环境变量
    private static func debuggerPresent() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0,
           info.kp_proc.p_flag & P_TRACED != 0 {
            return true
        }
        for key in ["DYLD_INSERT_LIBRARIES", "DYLD_PRINT_LIBRARIES",
                    "DYLD_PRINT_APIS", "XCTestSessionIdentifier"] {
            if getenv(key) != nil { return true }
        }
        return false
    }

    /// 已加载动态库里混进了注入器/脱壳器。名单混淆存放（每个字节 ^0x5A），
    /// 二进制 strings 里扫不出明文，逆向的人不知道我们盯着哪些框架
    private static func hostileLibraries() -> Bool {
        let blacklist = [
            [0x3C, 0x28, 0x33, 0x3E, 0x3B],
            [0x39, 0x23, 0x39, 0x28, 0x33, 0x2A, 0x2E],
            [0x29, 0x2F, 0x38, 0x29, 0x2E, 0x28, 0x3B, 0x2E, 0x3F],
            [0x29, 0x29, 0x36, 0x77, 0x31, 0x33, 0x36, 0x36,
             0x77, 0x29, 0x2D, 0x33, 0x2E, 0x39, 0x32],
            [0x36, 0x33, 0x38, 0x3F, 0x28, 0x2E, 0x23],
            [0x29, 0x32, 0x3B, 0x3E, 0x35, 0x2D],
            [0x22, 0x39, 0x35, 0x34],
            [0x2E, 0x29, 0x2A, 0x28, 0x35, 0x2E, 0x3F, 0x39, 0x2E, 0x35, 0x28],
            [0x3C, 0x33, 0x29, 0x32, 0x32, 0x35, 0x35, 0x31],
        ].map { String(bytes: $0.map { $0 ^ 0x5A }, encoding: .utf8) ?? "" }
        let n = _dyld_image_count()
        for i in 0..<n {
            guard let path = _dyld_get_image_name(i) else { continue }
            let name = String(cString: path).lowercased()
            if blacklist.contains(where: { name.contains($0) }) {
                return true
            }
        }
        return false
    }

    /// 包里混进了动态库。全线静态链接 正常包内根本没有 Frameworks 目录，
    /// 重签注 Frida Gadget / tweak dylib 一进来就现形。
    private static func bundledInjectables() -> Bool {
        let fm = FileManager.default
        let roots = [Bundle.main.bundlePath]
        for root in roots {
            let fw = root + "/Frameworks"
            if fm.fileExists(atPath: fw) {
                if let names = try? fm.contentsOfDirectory(atPath: fw),
                   names.contains(where: { $0.lowercased().hasSuffix(".dylib") }) {
                    return true
                }
            }
            if let names = try? fm.contentsOfDirectory(atPath: root) {
                for n in names where n.lowercased().hasSuffix(".dylib") {
                    return true
                }
            }
        }
        return false
    }

    /// 清掉注入类环境变量 子进程不带走
    private static func clearInjectionEnv() {
        for key in ["DYLD_INSERT_LIBRARIES", "DYLD_PRINT_LIBRARIES", "DYLD_PRINT_APIS"] {
            unsetenv(key)
        }
    }

    /// 二进制完整性自证：把自己 Mach-O 的 SHA256 报给服务器对账。
    /// 只用来看「有没有被大规模重打包流通」，**判定结果不再驱动任何本地行为**：
    /// 自签安装本来就会改变哈希，拿它当退出条件是纯误杀。
    static func reportBinaryIntegrity() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            guard let cpath = _dyld_get_image_name(0) else { return }
            let path = String(cString: cpath)
            guard let sha = Self.fileSHA256(path) else { return }
            let isExt = Bundle.main.bundleURL.pathExtension == "appex"
            let ver = (Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
            AnRanAPI.shared.reportIntegrity(version: ver,
                                            target: isExt ? "ext" : "main",
                                            sha: sha) { tampered in
                // 只记录，不退出（见文件头说明）
                if tampered { Self.report("bininteg") }
            }
        }
    }

    /// 大文件流式 SHA256（键盘扩展内存受限 分 1MB 一段读）
    private static func fileSHA256(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        while true {
            let chunk = fh.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { raw in
                _ = CC_SHA256_Update(&ctx, raw.baseAddress, CC_LONG(chunk.count))
            }
        }
        var dig = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&dig, &ctx)
        return dig.map { String(format: "%02x", $0) }.joined()
    }
}

/// 关键字符串轻混淆：二进制 strings 里扫不出来 用到时才还原
enum SecStr {
    static func dec(_ key: UInt8, _ bytes: [UInt8]) -> String {
        String(bytes: bytes.map { $0 ^ key }, encoding: .utf8) ?? ""
    }
}
