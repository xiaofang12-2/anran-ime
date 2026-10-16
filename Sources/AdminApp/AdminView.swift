import SwiftUI

/// 账号管理主列表：加号 / 删除 / 详情（禁用 · 续期 · 解绑 · 快照）
struct AdminListView: View {

    @State private var accounts: [AdminAPI.Account] = []
    @State private var busy = true
    @State private var showCreate = false
    @State private var created = ""          // 刚建号的「用户名 密码」提示文本
    @State private var navError = ""

    var body: some View {
        List {
            if !navError.isEmpty {
                Text(navError).font(.footnote).foregroundColor(.red)
            }
            ForEach(accounts, id: \.id) { a in
                NavigationLink { AdminDetailView(account: a, onChanged: reload) } label: {
                    row(a)
                }
            }
            .onDelete { idx in
                let targets = idx.map { accounts[$0] }
                for a in targets {
                    AdminAPI.shared.delete(accountId: a.id) { ok, err in
                        if !ok { navError = "删除失败 \(err)" }
                        reload()
                    }
                }
            }
        }
        .navigationTitle("账号管理")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    AdminAPI.logout()
                } label: {
                    Text("退出").foregroundColor(.red)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await reloadAsync() }
        .overlay {
            if busy && accounts.isEmpty {
                ProgressView()
            } else if !busy && accounts.isEmpty && navError.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("还没有账号 点右上角 + 创建")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .sheet(isPresented: $showCreate, onDismiss: reload) {
            CreateSheet(created: $created)
        }
        .onChange(of: created) { _ in if !created.isEmpty { reload() } }
        .onAppear(perform: reload)
    }

    private func row(_ a: AdminAPI.Account) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(a.username).font(.body.weight(.semibold))
                if a.disabled {
                    Text("已禁用")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
                if a.expireAt != 0 && a.expireAt <= Int(Date().timeIntervalSince1970) {
                    Text("已过期")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.orange))
                }
            }
            HStack(spacing: 10) {
                ForEach(a.devices, id: \.machine) { d in
                    Label(d.platform == "ios" ? "iPhone" : "PC",
                          systemImage: d.platform == "ios" ? "iphone" : "desktopcomputer")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if a.note.isEmpty == false {
                    Text(a.note).font(.caption).foregroundColor(.secondary)
                }
                if a.phone.isEmpty == false {
                    Text(a.phone).font(.caption).foregroundColor(.blue)
                }
            }
            HStack(spacing: 10) {
                Text(expireText(a.expireAt)).font(.caption2).foregroundColor(.secondary)
                Text("最后登录 \(timeText(a.lastLoginAt))")
                    .font(.caption2).foregroundColor(.secondary)
                if a.snapSize > 0 {
                    Text("快照 \(a.snapSize / 1024)KB")
                        .font(.caption2).foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        busy = true
        AdminAPI.shared.accounts { list in
            busy = false
            if list.isEmpty && AdminAPI.isLoggedIn == false {
                navError = "会话失效，退出后重新登录"
            }
            accounts = list
        }
    }

    private func reloadAsync() async {
        await withCheckedContinuation { c in
            AdminAPI.shared.accounts { list in
                accounts = list
                c.resume()
            }
        }
    }

    private func expireText(_ exp: Int) -> String {
        guard exp != 0 else { return "永久" }
        let left = exp - Int(Date().timeIntervalSince1970)
        return left <= 0 ? "已过期" : "剩 \(max(1, left / 86400)) 天"
    }

    private func timeText(_ ts: Int) -> String {
        guard ts != 0 else { return "从未" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// MARK: - 建号弹窗

private struct CreateSheet: View {
    @Binding var created: String
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var note = ""
    @State private var password = ""     // 留空 = 服务端自动生成
    @State private var days = 30         // 有效期天数，0 = 永久
    @State private var busy = false
    @State private var errorMessage = ""
    @State private var newPassword = ""

    private let dayOptions = [7, 30, 90, 365]

    var body: some View {
        NavigationView {
            Form {
                Section("新账号") {
                    TextField("用户名（必填）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $note)
                }
                Section("有效期") {
                    Picker("能用多久", selection: $days) {
                        ForEach(dayOptions, id: \.self) { Text("\($0) 天").tag($0) }
                        Text("永久").tag(0)
                    }
                    .pickerStyle(.segmented)
                }
                Section("密码") {
                    HStack {
                        TextField("留空自动生成", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !password.isEmpty {
                            Button { password = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !password.isEmpty && password.count < 6 {
                        Text("密码太短 至少 6 位").font(.footnote).foregroundColor(.orange)
                    }
                }
                Section {
                    Button(busy ? "创建中…" : "创建账号") {
                        create()
                    }
                    .disabled(busy || username.trimmingCharacters(in: .whitespaces).isEmpty
                              || (!password.isEmpty && password.count < 6))
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(.footnote).foregroundColor(.red)
                    }
                }
                if !newPassword.isEmpty {
                    Section("创建成功 把密码发给用户") {
                        Text(newPassword)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = newPassword
                        } label: {
                            Label("复制密码", systemImage: "doc.on.doc")
                        }
                        Button("完成") {
                            created = username
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("添加账号")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func create() {
        busy = true
        errorMessage = ""
        let u = username.trimmingCharacters(in: .whitespaces)
        AdminAPI.shared.create(username: u, note: note, password: password, days: days) { res in
            if !res.ok {
                busy = false
                errorMessage = res.error.isEmpty ? "创建失败" : "失败：\(res.error)"
                return
            }
            // 永久 = 建完把到期时间改成 0（服务端建号接口不认 days=0）
            if days == 0 {
                AdminAPI.shared.update(accountId: res.id, expireAt: 0) { ok, err in
                    busy = false
                    if ok {
                        newPassword = res.password
                    } else {
                        errorMessage = "已建号 但设永久失败：\(err)"
                        newPassword = res.password
                    }
                }
            } else {
                busy = false
                newPassword = res.password
            }
        }
    }
}

// MARK: - 账号详情：禁用 / 续期 / 解绑 / 用户快照

private struct AdminDetailView: View {
    let account: AdminAPI.Account
    let onChanged: () -> Void

    @State private var disabled = false
    @State private var note = ""
    @State private var phone = ""
    @State private var phoneEdit = ""
    @State private var phoneAt = 0
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("账号") {
                HStack { Text("用户名"); Spacer(); Text(account.username).foregroundColor(.secondary) }
                HStack { Text("ID"); Spacer(); Text("\(account.id)").foregroundColor(.secondary) }
                HStack {
                    Text("用户手机号")
                    Spacer()
                    TextField("未填写", text: $phoneEdit)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    Button("保存") {
                        if phoneEdit != account.phone { save(.phone(phoneEdit)) }
                    }
                    .buttonStyle(.borderless)
                }
                if phoneAt > 0 {
                    Text("填于 \(phoneDate)  点号码可直接改")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Toggle("禁用该账号", isOn: $disabled)
                    .onChange(of: disabled) { v in
                        save(.disabled(v))
                    }
                HStack { Text("备注"); TextField("无", text: $note, onCommit: { save(.note(note)) }) }
            }

            Section("到期时间") {
                Button("续期 30 天") { save(.expire(Int(Date().timeIntervalSince1970) + 30 * 86400)) }
                Button("续期 90 天") { save(.expire(Int(Date().timeIntervalSince1970) + 90 * 86400)) }
                Button("续期一年") { save(.expire(Int(Date().timeIntervalSince1970) + 365 * 86400)) }
                Button("设为永久") { save(.expire(0)) }
            }

            Section("绑定设备（解绑后用户可重新登录绑定）") {
                if account.devices.isEmpty {
                    Text("无绑定设备").foregroundColor(.secondary)
                }
                ForEach(account.devices, id: \.machine) { d in
                    HStack {
                        Image(systemName: d.platform == "ios" ? "iphone" : "desktopcomputer")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.platform == "ios" ? "iPhone" : "PC")
                                .font(.subheadline)
                            Text(d.machine)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("解绑") { save(.unbind(d.machine)) }
                            .buttonStyle(.borderless)
                            .foregroundColor(.red)
                    }
                }
                if !account.devices.isEmpty {
                    Button("解绑全部设备", role: .destructive) { save(.unbind("all")) }
                }
            }

            Section("用户快照（思想库 / 自定义短语）") {
                NavigationLink {
                    SnapshotView(accountId: account.id)
                } label: {
                    Label("查看用户配置快照", systemImage: "doc.text.magnifyingglass")
                }
            }

            if !message.isEmpty {
                Section { Text(message).font(.footnote).foregroundColor(.secondary) }
            }
        }
        .navigationTitle(account.username)
        .onAppear {
            disabled = account.disabled
            note = account.note
            phone = account.phone
            phoneEdit = account.phone
            phoneAt = account.phoneAt
            // 老账号：手机号只存在旧快照里（服务端入库前的数据），兜底读一次
            if account.phone.isEmpty { loadPhoneFromSnapshot() }
        }
    }

    /// 服务端入库（2026-10-16）之前绑定的号只随旧快照走，从快照里补读
    private func loadPhoneFromSnapshot() {
        AdminAPI.shared.snapshot(accountId: account.id) { ok, plain in
            guard ok,
                  let data = plain.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let p = (obj["phone"] as? String) ?? ""
            if !p.isEmpty && phone.isEmpty {
                phone = p
                phoneAt = (obj["phone_at"] as? NSNumber)?.intValue ?? 0
            }
        }
    }

    private var phoneDate: String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(phoneAt)))
    }

    private enum Action {
        case disabled(Bool)
        case expire(Int)
        case note(String)
        case phone(String)
        case unbind(String)
    }

    private func save(_ action: Action) {
        guard !busy else { return }
        busy = true
        let done: (Bool, String) -> Void = { ok, err in
            busy = false
            message = ok ? "已保存 \(timeNow())" : "失败：\(err)"
            if ok { onChanged() }
        }
        switch action {
        case .disabled(let v):
            AdminAPI.shared.update(accountId: account.id, disabled: v, completion: done)
        case .expire(let t):
            AdminAPI.shared.update(accountId: account.id, expireAt: t, completion: done)
        case .note(let n):
            AdminAPI.shared.update(accountId: account.id, note: n, completion: done)
        case .phone(let p):
            AdminAPI.shared.update(accountId: account.id, phone: p) { ok, err in
                if ok {
                    phone = p
                    phoneAt = Int(Date().timeIntervalSince1970)
                }
                done(ok, err)
            }
        case .unbind(let m):
            AdminAPI.shared.unbind(accountId: account.id, machine: m, completion: done)
        }
    }

    private func timeNow() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - 用户快照查看（思想库 / 自定义短语）

private struct SnapshotView: View {
    let accountId: Int
    @State private var text = "加载中…"
    @State private var ok = true

    var body: some View {
        Group {
            if ok {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 34))
                        .foregroundColor(.secondary)
                    Text(text).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("用户快照")
        .onAppear(perform: load)
    }

    private func load() {
        AdminAPI.shared.snapshot(accountId: accountId) { success, plain in
            ok = success
            if success {
                // 上报的是 JSON，把转义压掉、键排序好读一点
                if let data = plain.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    if let pretty = try? JSONSerialization.data(
                        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                       let s = String(data: pretty, encoding: .utf8) {
                        text = s
                        return
                    }
                }
                text = plain
            } else {
                text = plain.isEmpty ? "该用户还没有上报过快照" : plain
            }
        }
    }
}
