import UIKit
import SwiftUI

/// 键盘扩展入口
///
/// 阶段 0 只做「能弹出 + 能敲英文字母」，用来验证整条链路：
/// 云 Mac 编译 -> 出 ipa -> 自签安装 -> 设置里启用 -> 真机弹出。
/// 拼音引擎（librime）和思想库留到阶段 1 / 阶段 2。
final class KeyboardViewController: UIInputViewController {

    private var hosting: UIHostingController<KeyboardRootView>?

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

        view.heightAnchor.constraint(equalToConstant: 268).isActive = true
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
