import UIKit
import SwiftUI

/// 键盘扩展入口
///
/// 拼音引擎在 `PinyinEngine`（本地词库 + 前缀/切分出候选），
/// 界面在 `KeyboardRootView`。这里只负责往当前输入框塞字、管占位文本与授权心跳。
final class KeyboardViewController: UIInputViewController {

    private var hosting: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()

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
        let h = KBMetrics.totalHeight(rows: n)
        guard let c = heightConstraint, abs(c.constant - h) > 0.5 else { return }
        c.constant = h
        view.setNeedsLayout()
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshAuth()
    }

    // MARK: - 授权

    /// 心跳续票据：能连上就刷新，连不上先用本机缓存撑着（离线宽限）
    /// 只有服务端明确说禁用 / 解绑 / 无此账号，才把登录态清掉
    func refreshAuth() {
        guard let s = AuthStore.current, !s.ticket.isEmpty else { return }
        AnRanAPI.shared.heartbeat(ticket: s.ticket, machine: s.machine) { res in
            if res.ok {
                AuthStore.save(username: s.username, ticket: res.ticket,
                               expireAt: res.expireAt)
            } else if ["disabled", "unbound", "no_account",
                       "machine_mismatch"].contains(res.error) {
                AuthStore.clear()
            }
        }
    }

    /// 跳到主程序登录（主程序声明了 anranime:// 这个 scheme）
    func openHostApp() {
        guard let url = URL(string: "anranime://login") else { return }
        extensionContext?.open(url, completionHandler: nil)
    }
}

/// 让 `UIDevice.current.playInputClick()` 能出声（按键音）
extension KeyboardViewController: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}