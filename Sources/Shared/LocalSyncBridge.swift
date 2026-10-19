import Foundation

/// 同设备秒同步门铃：主 app 改完配置按一下，键盘（哪怕正开着）立刻来拉。
///
/// 只按铃、不带数据 —— 数据走 LocalSyncLink 的回环 TCP（用户要求不碰剪贴板）。
/// Darwin 通知中心跨进程投递、不经过沙盒，iOS 上键盘扩展与宿主 app 通信的
/// 标准旁路；不弹任何隐私横幅。
///
/// 为什么需要它：App Group 用不了（免费 Apple ID 自签限制，见 SharedStore 注释），
/// 主 app 与键盘扩展各困各的沙盒；配置同步原路径全量走服务器中转 —— 推送侧
/// 1.5 秒节流、两跳网络、键盘还只在弹出时拉一次，改个设置要等一两秒。
/// 门铃 + 回环拉取把同设备延迟压到几十毫秒。
///
/// 分层兜底：
/// - 键盘没在运行没听到门铃 → 下次弹出 viewWillAppear 先连本地 server 拉，
///   连不上再照旧走服务器拉取（主 app 被杀时也不丢）；
/// - 服务器推送链路原样保留，多设备/账号维度不受影响。
enum LocalSyncBridge {

    /// 门铃名。Darwin 通知中心跨进程投递、不经过沙盒。
    /// （Xcode 16 SDK 起 CFNotificationName 是独立结构体，要用 rawValue 构造）
    static let ringName = CFNotificationName(
        rawValue: "com.anran.ime.config.ring" as CFString)

    // MARK: - 写方（主 app 调）

    /// 按下门铃。不携带数据、不阻塞；键盘听到会自己去 LocalSyncLink 拉整包。
    static func ring() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ringName, nil, nil, true)
    }

    // MARK: - 门铃（键盘侧注册）

    /// 注册门铃监听。返回的句柄被释放时自动摘除监听，
    /// 调用方持有它多久就听多久（键盘会话级）。
    static func addRing(_ handler: @escaping () -> Void) -> RingHandle {
        RingHandle(handler)
    }
}

/// 门铃监听句柄：持有期间监听 Darwin 通知，deinit 自动摘除。
/// 文件级类型（不是 LocalSyncBridge 成员），引用时直接写 RingHandle。
final class RingHandle {

    private let ptr: UnsafeMutableRawPointer

    init(_ handler: @escaping () -> Void) {
        let box = RingBox(handler)
        ptr = Unmanaged.passRetained(box).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ptr,
            anranRingCallback,
            // 注意：AddObserver 的 name 形参在这个 SDK 里收 CFString?
            // （PostNotification 才收 CFNotificationName），取 rawValue 过
            LocalSyncBridge.ringName.rawValue, nil,
            CFNotificationSuspensionBehavior.deliverImmediately)
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), ptr, nil, nil)
        Unmanaged<RingBox>.fromOpaque(UnsafeRawPointer(ptr)).release()
    }
}

/// 闭包盒子：C 回调拿不到 Swift 捕获上下文，经它中转。
/// （CrashReporter 同款教训：@convention(c) 回调必须是文件级函数。）
private final class RingBox {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
}

/// 文件级 C 回调。签名按 Xcode 16 SDK 的 CFNotificationCallback：
/// observer 是 UnsafeMutableRawPointer?。
/// Darwin 通知可能从任意线程投递，由 handler 内部自己负责 hop 主线程。
private func anranRingCallback(_ center: CFNotificationCenter?,
                               _ observer: UnsafeMutableRawPointer?,
                               _ name: CFNotificationName?,
                               _ object: UnsafeRawPointer?,
                               _ userInfo: CFDictionary?) {
    guard let observer else { return }
    let box = Unmanaged<RingBox>.fromOpaque(
        UnsafeRawPointer(observer)).takeUnretainedValue()
    box.handler()
}
