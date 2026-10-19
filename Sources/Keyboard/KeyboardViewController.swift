import UIKit
import SwiftUI

/// 键盘扩展入口
///
/// 拼音引擎在 `PinyinEngine`（本地词库 + 前缀/切分出候选），
/// 界面在 `KeyboardRootView`。这里只负责往当前输入框塞字、管占位文本与授权心跳。
final class KeyboardViewController: UIInputViewController {

    private var hosting: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?
    /// 展开的浮层面板额外占的高度（剪贴板/思想库），跟着行高一起算总高
    private var extraHeight: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        Hardening.arm()
        CrashReporter.install()

        let root = KeyboardRootView(controller: self)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hosting = host

        // 26 键 4 行，高度按用户在「键盘布局」里调的键高算
        let h = KBMetrics.totalHeight(rows: KBMetrics.rows)
        let c = view.heightAnchor.constraint(equalToConstant: h)
        c.isActive = true
        heightConstraint = c
    }

    /// 主程序改了键高/间距后调一次，把键盘高度跟着重算，否则行会被裁掉
    func setRows(_ n: Int) {
        let h = KBMetrics.totalHeight(rows: n, extra: extraHeight)
        guard let c = heightConstraint, abs(c.constant - h) > 0.5 else { return }
        c.constant = h
        view.setNeedsLayout()
    }

    /// 功能栏点开/收起浮层面板时调一次，把多出来的高度算进键盘总高
    func setExtraHeight(_ extra: CGFloat) {
        extraHeight = extra
        setRows(KBMetrics.rows)
    }

    // MARK: - 往当前 app 的输入框里塞字

    func insert(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    func backspace() {
        textDocumentProxy.deleteBackward()
    }

    func newline() {
        textDocumentProxy.insertText("\n")
    }

    /// 空格键左右滑动：挪光标
    func moveCursor(_ delta: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: delta)
    }

    /// 拼音串只在键盘自己的候选栏里显示，不往宿主输入框里写占位文本。
    /// （用户明确要求：字母待在输入法内，平台输入框里只落最终汉字）
    func setComposing(_ text: String) {
        _ = text
    }

    /// 上屏一个词：直接插进宿主输入框
    func commit(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    /// 上屏 + 按回车发送（思想库面板回车用）。
    ///
    /// 正文和回车必须**分两次、隔一个 runloop 插**：同一个调用栈里连着插，
    /// 微信 / QQ 这类聊天框会把它们并成一次编辑，只落一个换行、不触发发送。
    /// 隔开之后宿主先收到正文、再收到一次独立的「回车」，才会真的发出去。
    func commitAndSend(_ text: String) {
        textDocumentProxy.insertText(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.textDocumentProxy.insertText("\n")
        }
    }

    /// 思想库逐字上屏：内容一个字一个字插进宿主输入框（打字机效果），
    /// 字间隔由「输入设置 → 思想库上屏间隔」控制（内部兜底 35ms —— 再快宿主
    /// App 的文本监听就来不及收字，会吞字）。插完隔一拍补一次回车发送，
    /// **回车后再等一拍才回调 done**：宿主要花一拍处理「发送」并清空输入框，
    /// 下一句要是立刻开打，头几个字会被并进上一条消息或被清空
    /// （用户视频里的吞字/串句就是这个）。done 在主线程回调。
    func sendTypewriter(_ text: String, speedMs: Int, done: @escaping () -> Void) {
        let chs = Array(text)
        let gap = UInt64(max(35, speedMs)) * 1_000_000
        Task { @MainActor [weak self] in
            for ch in chs {
                self?.textDocumentProxy.insertText(String(ch))
                try? await Task.sleep(nanoseconds: gap)
            }
            // 正文插完与回车之间至少隔一拍，聊天框才会当成两次编辑
            try? await Task.sleep(nanoseconds: max(gap, 80_000_000))
            self?.textDocumentProxy.insertText("\n")
            // 给宿主一拍处理发送并清空输入框，下一句才能从头打
            try? await Task.sleep(nanoseconds: 220_000_000)
            done()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshAuth()
        // 会话中每 30 秒再心跳一次：后台禁用账号后，用户不用收起键盘
        // 也会在半分钟内被踢下线（服务端对禁用账号的心跳直接回 403 disabled）
        if hbTimer == nil {
            hbTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.refreshAuth()
            }
        }
        // 秒同步门铃：主 app 改设置/短语/思想库后几十毫秒内推着整包过来，
        // 键盘哪怕正开着也立刻落盘刷新（App Group 用不了，总线走
        // Darwin 通知 + 命名剪贴板，见 LocalSyncBridge）。
        // 扩展进程存活期间只注册一次；viewWillDisappear 摘掉。
        if ringHandle == nil {
            ringHandle = LocalSyncBridge.addRing {
                // Darwin 回调线程不定，落盘/UI 只认主线程
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .anranLocalBusRing, object: nil)
                }
            }
        }
        // 键盘每次弹出都让界面重拉一次主程序下发的配置。
        // 配置（布局/自定义短语/设置/思想库）双通道同步：本地总线秒推 +
        // 服务器整包兜底，而 SwiftUI 的 onAppear 在扩展进程存活期间只会
        // 触发一次 —— 不补这一下，主程序改完短语再回到键盘不会更新，
        // 表现为「设置了自定义等于没设置」。
        NotificationCenter.default.post(name: .anranKeyboardWillAppear, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hbTimer?.invalidate()
        hbTimer = nil
        ringHandle = nil
    }

    private var hbTimer: Timer?
    /// 秒同步门铃句柄：nil = 没在听
    private var ringHandle: RingHandle?

    // MARK: - 授权

    /// 心跳续票据：能连上就刷新，连不上先用本机缓存撑着（离线宽限）
    /// 只有服务端明确说禁用 / 解绑 / 无此账号，或账号在别处退登过（登出序号
    /// 对不上），才把登录态清掉 —— 键盘立刻锁死切回登录墙
    func refreshAuth() {
        guard let s = AuthStore.current, !s.ticket.isEmpty else { return }
        AnRanAPI.shared.heartbeat(ticket: s.ticket, machine: s.machine,
                                  client: "kb") { res in
            if ["disabled", "unbound", "no_account",
                "machine_mismatch"].contains(res.error) {
                AuthStore.clear()
                // 界面层立刻收到广播切回登录墙，不等下一次 pull
                NotificationCenter.default.post(name: .anranAuthKicked, object: nil)
            } else if res.ok {
                if let seq = res.logoutSeq, seq != (s.logoutSeq ?? 0) {
                    AuthStore.clear()
                    NotificationCenter.default.post(name: .anranAuthKicked, object: nil)
                    return
                }
                AuthStore.save(username: s.username, ticket: res.ticket,
                               expireAt: res.expireAt,
                               logoutSeq: res.logoutSeq ?? s.logoutSeq)
            }
        }
    }

    /// 跳到主程序登录（主程序声明了 anranime:// 这个 scheme）
    func openHostApp() {
        openHost("login")
    }

    /// 跳到主程序某个页面：anranime://phrases / anranime://thoughts
    func openHost(_ path: String) {
        guard let url = URL(string: "anranime://" + path) else { return }
        extensionContext?.open(url, completionHandler: nil)
    }

    /// 功能栏右上角的收起按钮：把键盘收下去
    func dismissKeyboardNow() {
        dismissKeyboard()
    }
}

/// 让 `UIDevice.current.playInputClick()` 能出声（按键音）
extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

extension Notification.Name {
    /// 键盘每次弹出时广播一次，界面据此重新拉取主程序下发的配置
    static let anranKeyboardWillAppear = Notification.Name("anran.keyboard.willAppear")

    /// 服务端踢人（禁用/解绑）后广播一次，键盘界面立刻切回登录墙
    static let anranAuthKicked = Notification.Name("anran.auth.kicked")

    /// librime 后台部署收尾时广播一次（成功失败都发），界面据此刷新引擎诊断串
    static let anranRimeReady = Notification.Name("anran.rime.ready")

    /// 秒同步门铃响了（主 app 刚改完配置）：界面立刻读本地总线落盘刷新
    static let anranLocalBusRing = Notification.Name("anran.local_bus.ring")
}