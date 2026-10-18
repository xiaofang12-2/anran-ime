import Foundation
import Darwin
import MachO

/// 全端防护（主程序 + 键盘扩展启动各调一次 arm()）：
///   1. ptrace(PT_DENY_ATTACH) —— 调试器一挂上进程直接断开；
///   2. csops 查 CS_DEBUGGED —— 启动前就被挂过的也认出来；
///   3. sysctl 查 P_TRACED + DYLD 注入环境变量巡检，看门狗每 3 秒巡一次；
///   4. SecStr 轻混淆 —— 关键字符串在二进制里不是明文。
enum Hardening {

    private static var armed = false

    static func arm() {
        guard !armed else { return }
        armed = true
        denyAttach()
        if debuggerPresent() || debugFlagged() || hostileLibraries()
              || bundledInjectables() { kill() }
        clearInjectionEnv()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            if debuggerPresent() || hostileLibraries() || bundledInjectables() {
                kill()
            }
        }
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

    /// 已加载动态库里混进了注入器/脱壳器（Frida Substrate cycript 之类）
    private static func hostileLibraries() -> Bool {
        let blacklist = ["frida", "cycript", "substrate", "ssl-kill-switch",
                         "liberty", "shadow", "xcon", "tsprotector", "fishhook"]
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

    /// 发现调试直接退 不弹任何提示不给分析现场
    private static func kill() {
        exit(0)
    }
}

/// 关键字符串轻混淆：二进制 strings 里扫不出来 用到时才还原
enum SecStr {
    static func dec(_ key: UInt8, _ bytes: [UInt8]) -> String {
        String(bytes: bytes.map { $0 ^ key }, encoding: .utf8) ?? ""
    }
}
