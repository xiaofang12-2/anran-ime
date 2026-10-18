import SwiftUI

/// 尾巴：思想库发出去的内容尾部统一带一个设置的符号。
struct TailSettingsView: View {
    @State private var s = IMESettingsStore.current
    @State private var draft = ""

    var body: some View {
        ZStack {
            ARTheme.softBackground.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    ARTheme.sectionTitle("尾巴")
                    ARTheme.card {
                        ARToggleRow(title: "开启尾巴",
                                    isOn: $s.tailEnabled)
                        arDivider()
                        HStack(spacing: 10) {
                            Text("尾巴符号")
                                .font(.system(size: 15))
                                .foregroundColor(.black.opacity(0.85))
                            Spacer(minLength: 8)
                            TextField("如 。", text: $draft)
                                .multilineTextAlignment(.center)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 64)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 9)
                                    .fill(Color.black.opacity(0.055)))
                                .onChange(of: draft) { v in
                                    let one = String(v.prefix(1))
                                    s.tailSymbol = one
                                    if v != one { draft = one }
                                }
                        }
                        .padding(.vertical, 9)
                    }

                    ARTheme.sectionTitle("效果预览")
                    ARTheme.card {
                        ARRow(title: "在吗") {
                            Text(preview)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(ARTheme.blue)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("尾巴")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: s) { newValue in
            IMESettingsStore.saveLocal(newValue)
            ConfigSync.publish(settings: newValue)
        }
    }

    private var preview: String {
        guard s.tailEnabled, !s.tailSymbol.isEmpty else { return "在吗" }
        return "在吗" + s.tailSymbol
    }
}
