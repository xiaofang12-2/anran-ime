import SwiftUI

@main
struct AnRanApp: App {
    init() {
        ARTheme.install()
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
