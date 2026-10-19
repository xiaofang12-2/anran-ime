import Foundation
import Darwin

/// 崩溃捕获：主程序、键盘扩展各自启动时装一次 install()。
///
/// 捕到的崩溃写到本沙盒 last_crash.txt（主程序/键盘互相读不到，
/// 主程序在「设置 → 关于 → 运行诊断」里看，键盘的露在候选栏诊断串）。
///
/// 信号处理里只允许 async-signal-safe 调用：open / write / close。
/// 处理函数必须是文件级全局函数 —— signal / NSSetUncaughtExceptionHandler
/// 要的是 @convention(c) 函数指针，写成闭包会因捕获上下文编译不过。
private var gCrashPath = [CChar](repeating: 0, count: 512)

private func anranSignalHandler(_ s: Int32) {
    gCrashPath.withUnsafeBufferPointer { p in
        guard let base = p.baseAddress, p.count > 1 else { return }
        let fd = open(base, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            let prefix: [CChar] = [115, 105, 103, 110, 97, 108, 32]   // "signal "
            prefix.withUnsafeBufferPointer { b in
                _ = write(fd, b.baseAddress, prefix.count)
            }
            var tmp = [CChar](repeating: 0, count: 12)
            var n = 0
            var v = s
            if v <= 0 {
                tmp[0] = 48; n = 1
            } else {
                while v > 0 { tmp[n] = CChar(truncatingIfNeeded: 48 + v % 10); v /= 10; n += 1 }
            }
            var out = [CChar](repeating: 0, count: 14)
            var i = 0
            while n > 0 { n -= 1; out[i] = tmp[n]; i += 1 }
            out[i] = 10; i += 1
            out.withUnsafeBufferPointer { b in _ = write(fd, b.baseAddress, i) }
            close(fd)
        }
    }
    signal(s, SIG_DFL)
    raise(s)
}

private func anranUncaughtHandler(_ ex: NSException) {
    let text = "exception \(ex.name.rawValue)\nreason \(ex.reason ?? "-")\n"
        + ex.callStackSymbols.prefix(24).joined(separator: "\n")
    try? text.write(toFile: String(cString: gCrashPath),
                    atomically: true, encoding: .utf8)
}

enum CrashReporter {

    private static var installed = false

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
        for i in 0..<min(pathBytes.count, gCrashPath.count) { gCrashPath[i] = pathBytes[i] }

        NSSetUncaughtExceptionHandler(anranUncaughtHandler)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, anranSignalHandler)
        }
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

    /// 当前进程常驻内存足迹。键盘扩展的 jetsam 红线约 60~70MB，
    /// 顶着这个数跑就是闪退高危；被系统杀掉时不留现场，只能靠这条串看。
    static func memoryDiag() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "mem -" }
        return "mem \(Int64(info.phys_footprint) / (1024 * 1024))M"
    }
}
