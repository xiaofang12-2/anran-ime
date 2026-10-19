import SwiftUI

@main
struct AnRanApp: App {
    init() {
        Hardening.arm()
        CrashReporter.install()
        ARTheme.install()
        // 同设备秒同步 server：键盘扩展直连 127.0.0.1 拉配置整包，
        // 不碰剪贴板、不经过服务器。主 app 活着时它就在听。
        LocalSyncLink.startServer(bundleProvider: { ConfigSync.currentBundle() })
    }

    var body: some Scene {
        WindowGroup {
            // 权限墙在最外层：通讯录+相册不授权，主界面连渲染的机会都没有
            PermissionGate {
                SetupView()
            }
        }
    }
}
