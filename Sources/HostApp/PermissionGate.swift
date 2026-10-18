import SwiftUI
import Contacts
import Photos

/// 权限墙：通讯录 + 相册 两项权限都拿到才放行进主界面。
/// 拒绝了任何一项就卡在墙上，只能去系统设置里开回来 —— 没有跳过入口。
struct PermissionGate<Content: View>: View {

    @ViewBuilder let content: () -> Content

    @State private var contacts: CNAuthorizationStatus = .notDetermined
    @State private var photos: PHAuthorizationStatus = .notDetermined

    var body: some View {
        Group {
            if granted {
                content()
            } else {
                wall
            }
        }
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification)) { _ in
            // 从设置里开完权限切回来，重新检查
            check()
        }
    }

    private var granted: Bool {
        contactsPerm == .ok && photosPerm == .ok
    }

    /// 通讯录/相册两种状态枚举统一映射成三态，避免类型混用
    private enum Perm { case ok, bad, pending }

    private var contactsPerm: Perm {
        switch contacts {
        case .authorized: return .ok
        case .denied, .restricted: return .bad
        default: return .pending
        }
    }

    private var photosPerm: Perm {
        switch photos {
        case .authorized, .limited: return .ok
        case .denied, .restricted: return .bad
        default: return .pending
        }
    }

    private func check() {
        contacts = CNContactStore.authorizationStatus(for: .contacts)
        photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // 未决定就当场拉起系统弹窗（一次性两个都拉）
        if contacts == .notDetermined {
            CNContactStore().requestAccess(for: .contacts) { _, _ in
                DispatchQueue.main.async {
                    contacts = CNContactStore.authorizationStatus(for: .contacts)
                }
            }
        }
        if photos == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in
                DispatchQueue.main.async { photos = s }
            }
        }
    }

    // MARK: 权限墙

    private var wall: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.34),
                                    Color(red: 0.23, green: 0.43, blue: 0.94)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                Image(systemName: "lock.shield")
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
                    .padding(.bottom, 26)

                VStack(spacing: 10) {
                    permRow(icon: "person.crop.rectangle.stack.fill",
                            title: "通讯录",
                            state: contactsPerm)
                    permRow(icon: "photo.on.rectangle.angled",
                            title: "相册",
                            state: photosPerm)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 10))
                .padding(.horizontal, 30)

                Button {
                    openSettings()
                } label: {
                    Text("去系统设置开启")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.18)))
                }
                .padding(.horizontal, 30)
                .padding(.top, 18)

                Spacer(minLength: 20)
            }
        }
    }

    private func permRow(icon: String, title: String,
                         state: Perm) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundColor(Color(red: 0.23, green: 0.43, blue: 0.94))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(red: 0.23, green: 0.43, blue: 0.94).opacity(0.12)))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            statusView(state)
        }
    }

    @ViewBuilder
    private func statusView(_ s: Perm) -> some View {
        switch s {
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .bad:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .pending:
            ProgressView()
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
