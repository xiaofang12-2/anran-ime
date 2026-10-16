import SwiftUI
import UIKit

/// 主界面：未登录 = 全屏登录墙（不登录看不到任何设置入口），已登录 = 设置主页
struct SetupView: View {

    @State private var logged = AuthStore.isLoggedIn

    /// 键盘功能栏点图标/长按跳过来时，程序化推对应设置页
    @State private var goPhrases = false
    @State private var goThoughts = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            if logged {
                HomeView(goPhrases: $goPhrases, goThoughts: $goThoughts,
                         onLogout: { logged = false })
            } else {
                LoginGateView(onLogin: { logged = true })
            }
        }
        .navigationViewStyle(.stack)
        // 建库/加关键词/加短语等任何 Store 落盘 → 立刻推剪贴板（不用等切后台），
        // 用户切出去打字键盘第一帧接到的就是新配置（对标百度个性短语加完就有）
        .onReceive(NotificationCenter.default.publisher(for: ConfigSync.localStoreChanged)) { _ in
            _ = ConfigSync.publishIfChanged()
            // 用户改了思想库/短语 → 顺手把新快照上报后台（管理端可查）
            SnapshotReport.uploadIfNeeded()
        }
        .onChange(of: scenePhase) { phase in
            // 切后台时把最新配置推给键盘（配置没变就不动剪贴板）。
            // 免费签名只能走剪贴板交接，这一步保证「改完设置 → 去别的 app 打字」
            // 键盘一开就是最新配置。
            if phase != .active {
                _ = ConfigSync.publishIfChanged()
                SnapshotReport.uploadIfNeeded()
            } else {
                // 回前台立刻验一次票：后台禁用/解绑的账号一回到主程序就被踢回登录墙
                kickCheck()
            }
        }
        // 主程序待着不动也要持续验票：后台一旦禁用，最迟一分钟主界面整体退回登录墙
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            kickCheck()
        }
        .onOpenURL { url in
            // 未登录时先拦在登录墙，登录成功后 goPhrases/goThoughts 还在，
            // 主页一渲染就会自动推到对应设置页
            switch url.host {
            case "phrases": goPhrases = true
            case "thoughts": goThoughts = true
            default: break
            }
        }
    }

    /// 服务端明确说禁用/解绑/无此号/设备不匹配 → 本地登录态作废，整体退回登录墙。
    /// 网络不通不算数（离线宽限，跟键盘端同一套口径）。
    private func kickCheck() {
        guard logged, let s = AuthStore.current, !s.ticket.isEmpty else { return }
        AnRanAPI.shared.heartbeat(ticket: s.ticket, machine: s.machine) { res in
            if ["disabled", "unbound", "no_account", "machine_mismatch"].contains(res.error) {
                AuthStore.clear()
                logged = false
            } else if res.ok {
                AuthStore.save(username: s.username, ticket: res.ticket, expireAt: res.expireAt)
            }
        }
    }
}

// MARK: - 登录墙：新用户第一眼看到的就是它

private struct LoginGateView: View {

    let onLogin: () -> Void

    @State private var inputUser = ""
    @State private var inputPass = ""
    @State private var busy = false
    @State private var message = ""
    @State private var messageBad = false
    /// 密码验证通过后等填手机号的账号（手机号必填 不填进不了主界面）
    @State private var pendingPhoneUser = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.34),
                                    Color(red: 0.23, green: 0.43, blue: 0.94)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            if pendingPhoneUser.isEmpty {
                loginCard
            } else {
                PhoneStepCard(username: pendingPhoneUser) {
                    pendingPhoneUser = ""
                    onLogin()
                }
            }
        }
    }

    private var loginCard: some View {
        VStack(spacing: 0) {
                Spacer(minLength: 24)

                // 立体图标位：白色磨砂圆角方 + 键盘符号
                Image(systemName: "keyboard")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Color(red: 0.23, green: 0.43, blue: 0.94))
                    .frame(width: 74, height: 74)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.25), radius: 14, y: 8))
                    .padding(.bottom, 16)

                Text("黯然输入法")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                Text("私有思想库 · 扣字利器")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.top, 4)
                    .padding(.bottom, 30)

                // 登录卡
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "person.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        TextField("账号", text: $inputUser)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(.secondarySystemBackground)))

                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        SecureField("密码", text: $inputPass)
                        if !inputPass.isEmpty {
                            Button {
                                inputPass = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color(.secondarySystemBackground)))

                    if !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(messageBad ? Color.red : Color.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        doLogin()
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "登录中…" : "登录")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.43, blue: 0.94),
                                                              Color(red: 0.36, green: 0.58, blue: 1.0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .shadow(color: Color(red: 0.23, green: 0.43, blue: 0.94).opacity(0.4),
                                        radius: 10, y: 5))
                    }
                    .disabled(busy || inputUser.isEmpty || inputPass.isEmpty)
                    .opacity(inputUser.isEmpty || inputPass.isEmpty ? 0.55 : 1)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 10))
                .padding(.horizontal, 30)

                Spacer(minLength: 24)

                Text("本机设备码 \(machineShort)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.bottom, 18)
        }
    }

    private var machineShort: String {
        let m = DeviceID.current
        return m.count > 12 ? String(m.prefix(12)) : m
    }

    private func doLogin() {
        busy = true
        message = ""
        let u = inputUser.trimmingCharacters(in: .whitespaces)
        AnRanAPI.shared.login(username: u,
                              password: inputPass,
                              machine: DeviceID.current) { res in
            busy = false
            if res.ok {
                AuthStore.save(username: u,
                               ticket: res.ticket, expireAt: res.expireAt)
                // 登录态并进整包推给键盘，省得用户再单独点一次「同步登录状态到键盘」
                ConfigSync.publish()
                // 登录成功就把用户快照交给后台（思想库/短语可被管理端查看）
                SnapshotReport.uploadIfNeeded()
                inputPass = ""
                // 手机号没填过的先去绑定页（必填），填过直接进
                if PhoneStore.phone(for: u) != nil {
                    onLogin()
                } else {
                    pendingPhoneUser = u
                }
                return
            }
            message = loginErrorText(res.error)
            messageBad = true
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
}

// MARK: - 手机号绑定步骤：登录密码通过后必经（自报号码 不发短信）

private struct PhoneStepCard: View {

    let username: String
    let onDone: () -> Void

    @State private var phone = ""
    @State private var msg = ""
    @State private var msgBad = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            Image(systemName: "iphone.gen3")
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(Color(red: 0.23, green: 0.43, blue: 0.94))
                .frame(width: 74, height: 74)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 14, y: 8))
                .padding(.bottom, 16)

            Text("绑定手机号")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
            Text("账号 \(username) 需绑定手机号后使用")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.72))
                .padding(.top, 4)
                .padding(.bottom, 30)

            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    TextField("请输入 11 位手机号", text: $phone)
                        .keyboardType(.numberPad)
                }
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(.secondarySystemBackground)))

                if !msg.isEmpty {
                    Text(msg)
                        .font(.footnote)
                        .foregroundColor(msgBad ? Color.red : Color.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    bind()
                } label: {
                    Text("绑定并进入")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 0.23, green: 0.43, blue: 0.94),
                                                              Color(red: 0.36, green: 0.58, blue: 1.0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .shadow(color: Color(red: 0.23, green: 0.43, blue: 0.94).opacity(0.4),
                                        radius: 10, y: 5))
                }
                .disabled(phone.isEmpty)
                .opacity(phone.isEmpty ? 0.55 : 1)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 18, y: 10))
            .padding(.horizontal, 30)

            Spacer(minLength: 24)

            Text("手机号仅作为账号归属标识 作者可在后台查看")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.55))
                .padding(.bottom, 18)
        }
    }

    private func bind() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        guard PhoneStore.isValid(p) else {
            msg = "手机号格式不对 11位 1开头"
            msgBad = true
            return
        }
        PhoneStore.save(phone: p, for: username)
        // 带着新手机号立刻上报一次 后台马上能看到
        SnapshotReport.uploadIfNeeded()
        msg = "绑定成功"
        msgBad = false
        onDone()
    }
}

// MARK: - 设置主页（只有登录后才能进来）

private struct HomeView: View {

    @Binding var goPhrases: Bool
    @Binding var goThoughts: Bool
    let onLogout: () -> Void

    @State private var who = AuthStore.current?.username ?? ""
    @State private var expireAt = AuthStore.current?.expireAt ?? 0
    @State private var phoneNow = ""
    @State private var showPhoneSheet = false
    @State private var message = ""
    @State private var messageBad = false

    var body: some View {
        List {
            accountSection
            functionSection
        }
        .navigationTitle("黯然输入法")
        .onAppear {
            refresh()
            // 已登录但手机号还没填的（老用户升级上来）必须补填才能用
            if PhoneStore.phone(for: who) == nil {
                showPhoneSheet = true
            }
            SnapshotReport.uploadIfNeeded()
        }
        .sheet(isPresented: $showPhoneSheet) {
            PhoneBindSheet(current: phoneNow, saved: phoneNow.isEmpty) { newPhone in
                phoneNow = newPhone
                SnapshotReport.uploadIfNeeded()
            }
            .interactiveDismissDisabled(phoneNow.isEmpty)
        }
    }

    // MARK: 账号

    private var accountSection: some View {
        Section("账号") {
            infoRow("账号", who)
            infoRow("手机号", phoneDisplay)
            infoRow("到期", expireText(expireAt))
            infoRow("本机设备码", machineShort, mono: true)
            Button {
                showPhoneSheet = true
            } label: {
                Label(phoneNow.isEmpty ? "绑定手机号" : "换绑手机号",
                      systemImage: "phone.arrow.left.and.right")
            }
            Button {
                if AuthStore.exportToPasteboard() {
                    tip("已放入剪贴板，去键盘里点「接取登录」", ok: true)
                } else {
                    tip("同步失败，请重新登录", ok: false)
                }
            } label: {
                Label("同步登录状态到键盘", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive) {
                AuthStore.clear()
                refresh()
                onLogout()
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(messageBad ? .red : .secondary)
            }
        }
    }

    // MARK: 功能入口

    private var functionSection: some View {
        Section("设置") {
            NavigationLink("输入设置") { SettingsView() }
            NavigationLink("自定义短语", isActive: $goPhrases) { PhraseSettingsView() }
            NavigationLink("思想库", isActive: $goThoughts) { ThoughtSettingsView() }
        }
    }

    // MARK: 工具

    private func refresh() {
        who = AuthStore.current?.username ?? ""
        expireAt = AuthStore.current?.expireAt ?? 0
        phoneNow = PhoneStore.phone(for: who) ?? ""
    }

    private var phoneDisplay: String {
        guard phoneNow.count == 11 else { return "未绑定" }
        return "\(phoneNow.prefix(3))****\(phoneNow.suffix(4))"
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
}

// MARK: - 手机号绑定/换绑弹层（首次绑定时不给下滑关闭）

private struct PhoneBindSheet: View {

    let current: String
    /// 首次绑定 = true（还没有号，不能白页滑走）
    let saved: Bool
    let onSaved: (String) -> Void

    init(current: String, saved: Bool, onSaved: @escaping (String) -> Void = { _ in }) {
        self.current = current
        self.saved = saved
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss
    @State private var phone = ""
    @State private var msg = ""
    @State private var msgBad = false

    var body: some View {
        NavigationView {
            Form {
                Section(current.isEmpty ? "绑定手机号" : "换绑手机号（当前 \(current)）") {
                    TextField("请输入 11 位手机号", text: $phone)
                        .keyboardType(.numberPad)
                    if !msg.isEmpty {
                        Text(msg)
                            .font(.footnote)
                            .foregroundColor(msgBad ? .red : .green)
                    }
                }
                Section {
                    Button("确认保存") { save() }
                        .disabled(!PhoneStore.isValid(phone))
                } footer: {
                    Text("手机号仅作为账号归属标识 作者可在后台查看 不发送任何短信")
                }
            }
            .navigationTitle("手机号")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !saved {
                        Button("关闭") { dismiss() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        let p = phone.trimmingCharacters(in: .whitespaces)
        guard let who = AuthStore.current?.username else {
            msg = "登录态丢失 请重新登录"
            msgBad = true
            return
        }
        guard PhoneStore.isValid(p) else {
            msg = "手机号格式不对 11位 1开头"
            msgBad = true
            return
        }
        PhoneStore.save(phone: p, for: who)
        onSaved(p)
        dismiss()
    }
}
