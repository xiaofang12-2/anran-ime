import SwiftUI
import UIKit

/// 阶段 0 的主界面：只干两件事
/// 1. 自检 App Group 通不通（决定键盘和主 app 能不能共享数据）
/// 2. 图文引导用户去设置里启用键盘，并提供一键跳转
struct SetupView: View {

    @State private var groupOK = SharedStore.isGroupAvailable

    var body: some View {
        NavigationView {
            List {
                Section("自检") {
                    HStack {
                        Image(systemName: groupOK
                              ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundColor(groupOK ? .green : .red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(groupOK ? "共享容器已连通" : "共享容器不可用")
                            Text(groupOK
                                 ? "键盘和主 app 可以共享词库与思想库"
                                 : "免费签名可能不支持 App Groups，需要走网络同步回退方案")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Button("重新自检") { groupOK = SharedStore.isGroupAvailable }
                }

                Section("启用键盘") {
                    StepRow(n: 1, text: "打开「设置 → 通用 → 键盘 → 键盘」")
                    StepRow(n: 2, text: "点「添加新键盘」，选「黯然输入法」")
                    StepRow(n: 3, text: "点进「黯然输入法」，打开「完全访问」")
                    Button("一键跳到键盘设置") { openKeyboardSettings() }
                        .foregroundColor(.accentColor)
                }

                Section("说明") {
                    Text("「完全访问」必须打开，否则键盘读不到自己的词库和思想库。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("黯然输入法")
        }
        .navigationViewStyle(.stack)
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
