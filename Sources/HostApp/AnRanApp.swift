import SwiftUI

@main
struct AnRanApp: App {
    init() {
        CrashReporter.install()
        ARTheme.install()
        // 同设备秒同步 server：键盘扩展直连 127.0.0.1 拉配置整包。
        // 纯本地，不碰剪贴板、不经过任何服务器、不需要账号。
        LocalSyncLink.startServer(bundleProvider: { ConfigSync.currentBundle() })
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

/// 冷启动 / 每次重新打开都播一次「欢迎尊贵的 SVIP 贵宾」。
/// scenePhase 放在 View 层（App 本身拿不到 environment）。
private struct AppRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showWelcome = true

    var body: some View {
        ZStack {
            PermissionGate {
                SetupView()
            }
            if showWelcome {
                SVIPWelcomeView {
                    withAnimation { showWelcome = false }
                }
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .onChange(of: scenePhase) { phase in
            // 从后台回到前台 = 用户「重新打开了软件」，再播一次
            if phase == .active && !showWelcome {
                showWelcome = true
            }
        }
    }
}
