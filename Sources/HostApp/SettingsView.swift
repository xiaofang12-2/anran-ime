import SwiftUI

/// 「输入设置」页：全部开关都真正生效。
/// 跟主页同一套「简约立体」主题：深蓝渐变底 + 白卡片（ARTheme），不再用系统 List。
struct SettingsView: View {

    @State private var s = IMESettingsStore.current
    @State private var message = ""

    var body: some View {
        ZStack {
            ARTheme.background
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    inputCard

                    ARTheme.sectionTitle("键盘")
                    ARTheme.card {
                        ARToggleRow(title: "按键音效",
                                    isOn: $s.keySound)
                        arDivider()
                        ARToggleRow(title: "按键震动",
                                    isOn: $s.vibration)
                        arDivider()
                        ARStepperRow(title: "候选数量",
                                     valueText: "\(s.candidateCount)",
                                     range: IMESettings.candidateRange,
                                     value: $s.candidateCount,
                                     note: "候选栏横条显示前 9 条，更多在展开网格里")
                        arDivider()
                        ARNumberFieldRow(title: "思想库上屏间隔",
                                    suffix: "ms",
                                    range: IMESettings.outputSpeedRange,
                                    value: $s.outputSpeed)
                    }

                    ARTheme.sectionTitle("个性化")
                    ARTheme.card {
                        ARNavRow(title: "键盘布局") { LayoutSettingsView() }
                        arDivider()
                        ARNavRow(title: "尾巴") { TailSettingsView() }
                    }

                    ARTheme.sectionTitle("词库")
                    ARTheme.card {
                        ARActionRow(title: "清空打字学习记录",
                                    icon: "trash",
                                    tint: Color(red: 0.85, green: 0.27, blue: 0.27)) {
                            clearLearn()
                        }
                    }

                    ARTheme.sectionTitle("关于")
                    ARTheme.card {
                        ARRow(title: "版本") {
                            Text(Self.version)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        arDivider()
                        ARActionRow(title: "运行诊断", icon: "waveform.path.ecg") {
                            message = CrashReporter.lastCrash().isEmpty
                                ? "无崩溃记录 \(CrashReporter.memoryDiag())"
                                : CrashReporter.lastCrash()
                        }
                    }

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundColor(Color.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 6)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 28)
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

    /// 「输入」卡片单独拆出来：body 里六七个 card 串成的大表达式，
    /// 加一行 Picker 就可能把 Swift 类型检查器顶超时（KeyboardRootView 栽过）。
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ARTheme.sectionTitle("输入")
            ARTheme.card {
                ARToggleRow(title: "模糊音",
                            isOn: $s.fuzzyPinyin)
                arDivider()
                ARToggleRow(title: "简拼 / 混拼",
                            isOn: $s.abbrevInput)
                arDivider()
                ARToggleRow(title: "智能纠错",
                            isOn: $s.smartCorrect)
                arDivider()
                ARRow(title: "拼音方案",
                      subtitle: "双拼两键一音节；模糊音 / 纠错 / 简拼对双拼同样生效") {
                    Picker("", selection: $s.doublePinyin) {
                        ForEach(DoublePinyinScheme.allCases, id: \.rawValue) { sc in
                            Text(sc.displayName).tag(sc.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 170)
                }
            }
        }
    }

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(v) (\(b))"
    }

    private func clearLearn() {
        s.clearLearnToken = Int(Date().timeIntervalSince1970)
        IMESettingsStore.saveLocal(s)
        if ConfigSync.publish(settings: s) {
            message = "已清空 键盘会自动同步"
        } else {
            message = "发送失败 请重试"
        }
    }
}
