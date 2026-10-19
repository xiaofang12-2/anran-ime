import Foundation
import UIKit

/// 同设备秒同步通道：Darwin 通知当门铃 + 命名剪贴板当数据总线。
///
/// 为什么需要它：App Group 用不了（免费 Apple ID 自签限制，见 SharedStore 注释），
/// 主 app 与键盘扩展各困各的沙盒；配置同步只能走服务器中转 —— 推送侧 1.5 秒节流、
/// 两跳网络、键盘还只在弹出时拉一次，改个设置要等一两秒。
/// 这条通道把同设备延迟压到几十毫秒：主 app 任何 Store 落盘后，把整包 JSON
/// 写进命名剪贴板再按一下 Darwin 门铃，键盘（哪怕正开着）立刻落盘刷新。
///
/// 分层兜底：
/// - 键盘没在运行没听到门铃 → 下次弹出 viewWillAppear 先读总线（剪贴板还在），
///   再照旧走服务器拉取（总线被系统清掉时也不丢）；
/// - 服务器推送链路原样保留，多设备/账号维度不受影响。
///
/// 剪贴板是自建命名板（不是 general），不弹隐私横幅，只在本机进程间传。
enum LocalSyncBridge {

    /// 门铃名。Darwin 通知中心跨进程投递、不经过沙盒，iOS 上键盘扩展
    /// 与宿主 app 通信的标准旁路。
    /// （Xcode 16 SDK 起 CFNotificationName 是独立结构体，要用 rawValue 构造）
    static let ringName = CFNotificationName(
        rawValue: "com.anran.ime.config.ring" as CFString)

    /// 数据总线名。命名剪贴板同设备跨进程可读写。
    static let boardName = UIPasteboard.Name(rawValue: "com.anran.ime.syncboard")

    private static var board: UIPasteboard? {
        UIPasteboard(name: boardName, create: true)
    }

    // MARK: - 写方（主 app 调）

    /// 把整包 JSON 写进总线并按下门铃。写完立刻返回，不阻塞调用方。
    @discardableResult
    static func post(_ json: String) -> Bool {
        guard let board else { return false }
        board.string = json
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            ringName, nil, nil, true)
        return true
    }

    // MARK: - 读方（键盘调）

    /// 读总线当前内容；nil = 没写过 / 被系统清了。
    static func read() -> String? {
        board?.string
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
