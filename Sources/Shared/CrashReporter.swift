import Foundation
import Darwin

/// 崩溃捕获：主程序、键盘扩展各自启动时装一次 install()。
///
/// 捕到的崩溃写到本沙盒 last_crash.txt（主程序/键盘互相读不到，
/// 主程序在「设置 → 关于 → 运行诊断」里看，键盘的露在候选栏诊断串）。
///
/// 信号处理里只允许 async-signal-safe 调用：open / write / close，
/// 数字转字符串手动拼、路径与缓冲都是 install() 时备好的既有内存，
/// 不做任何 Swift 运行时分配。
enum CrashReporter {

    private static var installed = false
    private static var sigPath = [CChar](repeating: 0, count: 512)

    static func install() {
        guard !installed else { return }
        installed = true

        // 上次崩溃的痕迹先挪成 last_crash_prev.txt（这次再崩不会抹掉上次现场）
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let cur = dir.appendingPathComponent("last_crash.txt").path
        let prev = dir.appendingPathComponent("last_crash_prev.txt").path
        try? fm.removeItem(atPath: prev)
        try? fm.moveItem(atPath: cur, toPath: prev)

        // 预存崩溃日志路径的 C 字节串（信号处理里直接 open 用）
        let pathBytes = Array(cur.utf8CString)
        for i in 0..<min(pathBytes.count, sigPath.count) { sigPath[i] = pathBytes[i] }

        // ObjC 异常：不在信号上下文，可以正常格式化
        NSSetUncaughtExceptionHandler { ex in
            let text = "exception \(ex.name.rawValue)\nreason \(ex.reason ?? "-")\n"
                + ex.callStackSymbols.prefix(24).joined(separator: "\n")
            try? text.write(toFile: crashPath(), atomically: true, encoding: .utf8)
        }

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                var digits: [CChar] = []
                var v = s
                repeat {
                    digits.insert(CChar(truncatingIfNeeded: 48 + v % 10), at: 0)
                    v /= 10
                } while v > 0
                var line = Array("signal ".utf8CString) + digits + Array("\n".utf8CString)
                sigPath.withUnsafeBufferPointer { p in
                    guard let base = p.baseAddress, p.count > 1 else { return }
                    // O_APPEND 追加写：这次崩了也不抹上一次的痕迹
                    let fd = open(base, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                    if fd >= 0 {
                        line.withUnsafeBufferPointer { buf in
                            _ = write(fd, buf.baseAddress, buf.count - 1)
                        }
                        close(fd)
                    }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }

    private static func crashPath() -> String {
        String(cString: sigPath)
    }

    /// 本沙盒最近一次崩溃（没有就是空串）。prev = 上上次的。
    static func lastCrash() -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        for name in ["last_crash.txt", "last_crash_prev.txt"] {
            let p = dir.appendingPathComponent(name)
            if let s = try? String(contentsOfFile: p.path, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return name == "last_crash_prev.txt" ? "[上次]\n" + s : s
            }
        }
        return ""
    }

    /// 当前进程内存：常驻足迹 / 距离被杀还剩多少（键盘扩展的 jetsam 红线看这个）
    static func memoryDiag() -> String {
        var available: Int64 = -1
        if #available(iOS 13.0, *) {
            available = Int64(os_proc_available_memory())
        }
        var footprint: Int64 = -1
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            footprint = Int64(info.phys_footprint)
        }
        let mb: (Int64) -> String = { $0 < 0 ? "-" : String($0 / (1024 * 1024)) + "M" }
        return "mem \(mb(footprint))/avail \(mb(available))"
    }
}
