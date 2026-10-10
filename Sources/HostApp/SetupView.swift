import SwiftUI
import UIKit

/// 主界面：账号登录 + 自检 + 启用键盘引导
struct SetupView: View {

    @State private var logged = AuthStore.isLoggedIn
    @State private var who = AuthStore.current?.username ?? ""
    @State private var expireAt = AuthStore.current?.expireAt ?? 0

    @State private var inputUser = ""
    @State private var inputPass = ""
    @State private var busy = false
    @State private var message = ""
    @State private var messageBad = false

    var body: some View {
        NavigationView {
            List {
                accountSection
                if logged { keyboardSection }
                selfCheckSection
                noteSection
            }
            .navigationTitle("黯然输入法")
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: refresh)
    }

    // MARK: - 账号

    @ViewBuilder
    private var accountSection: some View {
        Section("账号") {
            if logged {
                infoRow("账号", who)
                infoRow("到期", expireText(expireAt))
                infoRow("本机设备码", machineShort, mono: true)
                Button("同步登录状态到键盘") {
                    if AuthStore.exportToPasteboard() {
                        tip("已放入剪贴板，去键盘里点「接取登录」", ok: true)
                    } else {
                        tip("同步失败，请重新登录", ok: false)
                    }
                }
                Button("退出登录", role: .destructive) {
                    AuthStore.clear()
                    refresh()
                    tip("已退出", ok: true)
                }
            } else {
                TextField("账号", text: $inputUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $inputPass)
                Button(busy ? "登录中…" : "登录") { doLogin() }
                    .disabled(busy || inputUser.isEmpty || inputPass.isEmpty)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(messageBad ? .red : .secondary)
            }
        }
    }

    // MARK: - 启用键盘

    private var keyboardSection: some View {
        Section("启用键盘") {
            StepRow(n: 1, text: "打开「设置 → 通用 → 键盘 → 键盘」")
            StepRow(n: 2, text: "点「添加新键盘」，选「黯然输入法」")
            StepRow(n: 3, text: "点进「黯然输入法」，打开「完全访问」")
            Button("一键跳到键盘设置") { openKeyboardSettings() }
        }
    }

    // MARK: - 自检

    private var selfCheckSection: some View {
        Section("键盘怎么拿到登录态") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("靠「同步登录状态到键盘」交接")
                    Text("免费签名用不了 App Groups，登录后点上面那个按钮把票据放进剪贴板，"
                         + "再到键盘上点「接取登录」接过去。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var noteSection: some View {
        Section("说明") {
            Text("「完全访问」必须打开，否则键盘连不上网、读不到登录态。")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 动作

    private func refresh() {
        logged = AuthStore.isLoggedIn
        who = AuthStore.current?.username ?? ""
        expireAt = AuthStore.current?.expireAt ?? 0
    }

    private func doLogin() {
        busy = true
        message = ""
        AnRanAPI.shared.login(username: inputUser.trimmingCharacters(in: .whitespaces),
                              password: inputPass,
                              machine: DeviceID.current) { res in
            busy = false
            if res.ok {
                AuthStore.save(username: inputUser.trimmingCharacters(in: .whitespaces),
                               ticket: res.ticket, expireAt: res.expireAt)
                inputPass = ""
                refresh()
                tip(res.boundNew ? "登录成功，已绑定本机" : "登录成功", ok: true)
                return
            }
            tip(loginErrorText(res.error), ok: false)
        }
    }

    private func infoRow(_ label: String, _ value: String,
                         mono: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(mono ? .system(.footnote, design: .monospaced) : .body)
                .foregroundColor(.secondary)
        }
    }

    private func loginErrorText(_ code: String) -> String {
        switch code {
        case "bad_credential":   return "账号或密码不对"
        case "disabled":         return "账号已被禁用"
        case "bound_elsewhere":  return "该账号已绑定别的手机，请联系作者解绑"
        case "missing":          return "账号密码没填全"
        default:                 return "登录失败（\(code.isEmpty ? "网络不通" : code)）"
        }
    }

    private func tip(_ text: String, ok: Bool) {
        message = text
        messageBad = !ok
    }

    private func expireText(_ exp: Int) -> String {
        guard exp != 0 else { return "永久" }
        let d = Date(timeIntervalSince1970: TimeInterval(exp))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let left = exp - Int(Date().timeIntervalSince1970)
        if left <= 0 { return "已过期" }
        return "\(f.string(from: d))（剩 \(max(1, left / 86400)) 天）"
    }

    private var machineShort: String {
        let m = DeviceID.current
        return m.count > 12 ? String(m.prefix(12)) : m
    }

    /// 用私有 URL Scheme 直达键盘设置页
    /// 自签分发不走 App Store 审核，私有 API 可以放心用 —— 这点比正规上架自由
    private func openKeyboardSettings() {
        let direct = URL(string: "App-Prefs:root=General&path=Keyboard/KEYBOARDS")
        if let direct {
            UIApplication.shared.open(direct, options: [:]) { ok in
                if !ok, let fallback = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(fallback)
                }
            }
            return
        }
        if let fallback = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(fallback)
        }
    }
}

private struct StepRow: View {
    let n: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.footnote.bold())
                .foregroundColor(.accentColor)
                .frame(width: 20, height: 20)
                .background(
                    Circle().fill(Color.accentColor.opacity(0.15)))
            Text(text).font(.subheadline)
        }
        .padding(.vertical, 2)
    }
}