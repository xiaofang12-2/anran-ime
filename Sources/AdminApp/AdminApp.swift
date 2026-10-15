import SwiftUI

@main
struct AnRanAdminApp: App {
    var body: some Scene {
        WindowGroup {
            AdminRootView()
        }
    }
}

struct AdminRootView: View {
    @State private var logged = AdminAPI.isLoggedIn

    var body: some View {
        NavigationView {
            if logged {
                AdminListView()
            } else {
                AdminLoginView(onLogin: { logged = true })
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 管理员登录

private struct AdminLoginView: View {
    let onLogin: () -> Void
    @State private var password = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.12, blue: 0.16),
                                    Color(red: 0.26, green: 0.24, blue: 0.38)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Color(red: 0.55, green: 0.45, blue: 1.0))
                    .frame(width: 74, height: 74)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.25), radius: 14, y: 8))
                    .padding(.bottom, 16)

                Text("黯然后台管理")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                Text("账号 · 设备 · 用户快照")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.top, 4)
                    .padding(.bottom, 30)

                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "key.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .frame(width: 20)
                        SecureField("管理密码", text: $password)
                        if !password.isEmpty {
                            Button { password = "" } label: {
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
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        busy = true
                        message = ""
                        AdminAPI.shared.login(password: password) { ok, err in
                            busy = false
                            if ok {
                                password = ""
                                onLogin()
                            } else {
                                message = err == "unauthorized" || err.isEmpty
                                    ? "密码不对" : err
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(.white) }
                            Text(busy ? "验证中…" : "进入后台")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.35, blue: 0.95),
                                                              Color(red: 0.62, green: 0.5, blue: 1.0)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.95).opacity(0.4),
                                        radius: 10, y: 5))
                    }
                    .disabled(busy || password.isEmpty)
                    .opacity(password.isEmpty ? 0.55 : 1)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 10))
                .padding(.horizontal, 30)

                Spacer(minLength: 20)
            }
        }
    }
}
