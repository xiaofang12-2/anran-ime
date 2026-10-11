import SwiftUI

/// 「输入设置」页：对标百度的输入设置 / 键盘设置，全部开关都真正生效。
///
/// 免费签名用不了 App Groups，改完点「应用到键盘」把整包配置塞剪贴板，
/// 键盘下一次弹出时接过去（见 ConfigSync）。
struct SettingsView: View {

    @State private var s = IMESettingsStore.current
    @State private var message = ""
    @State private var messageBad = false

    var body: some View {
        List {
            Section {
                toggle("模糊音", $s.fuzzyPinyin,
                       "zh/z、ch/c、sh/s、前后鼻音、n/l 互相容错")
                toggle("简拼 / 混拼", $s.abbrevInput,
                       "nh → 你好，zme → 怎么，bjdx → 北京大学")
                toggle("智能纠错", $s.smartCorrect,
                       "按错相邻键也能出词，nihap → 你好")
                toggle("句首自动大写", $s.autoCapitalize,
                       "英文句首字母自动大写")
            } header: {
                Text("输入")
            }

            Section {
                toggle("按键音效", $s.keySound, "扣字按键音")
                toggle("按键震动", $s.vibration, "默认关闭，用按键音效替代")
                toggle("上滑输入数字", $s.swipeNumber, "字母键上滑打对应数字")
                Stepper(value: $s.candidateCount, in: IMESettings.candidateRange) {
                    HStack {
                        Text("候选数量")
                        Spacer()
                        Text("\(s.candidateCount)")
                            .font(.footnote.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("键盘")
            }

            Section {
                NavigationLink("键盘布局") { LayoutSettingsView() }
                NavigationLink("自定义短语") { PhraseSettingsView() }
            } header: {
                Text("个性化")
            }

            Section {
                Button("清空打字学习记录", role: .destructive) { clearLearn() }
            } header: {
                Text("词库")
            } footer: {
                Text("清掉键盘记住的「越用越靠前」词频，词库本身不动。")
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(Self.version)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("输入设置")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: s) { newValue in
            // 改一下立刻生效：存本机 + 推给键盘，不用再点「应用到键盘」
            IMESettingsStore.saveLocal(newValue)
            ConfigSync.publish(settings: newValue)
        }
    }

    // MARK: - 组件

    private func toggle(_ title: String, _ value: Binding<Bool>,
                        _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: value)
            Text(note)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(v) (\(b))"
    }

    // MARK: - 动作

    private func clearLearn() {
        s.clearLearnToken = Int(Date().timeIntervalSince1970)
        IMESettingsStore.saveLocal(s)
        if ConfigSync.publish(settings: s) {
            message = "已发送，去键盘上重新调出一次即清空"
            messageBad = false
        } else {
            message = "发送失败，请重试"
            messageBad = true
        }
    }
}
