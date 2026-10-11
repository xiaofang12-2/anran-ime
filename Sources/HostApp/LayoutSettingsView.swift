import SwiftUI

/// 「键盘布局」设置页：26 键每个键的高矮、宽窄、间距、圆角、字号，用户自己拖。
///
/// 拖一下即时存本机并推给键盘（见 KBConfigStore / ConfigSync），
/// 去键盘上重新调出一次就能看到，不用再点「应用到键盘」。
struct LayoutSettingsView: View {

    @State private var cfg = KBConfigStore.current

    var body: some View {
        List {
            Section("实时预览") {
                KBPreview(cfg: cfg)
                    .frame(height: 190)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                              bottom: 8, trailing: 12))
            }

            Section("按键尺寸") {
                row("按键高度", $cfg.keyHeight, 34...70, "pt")
                row("按键间距", $cfg.keyGap, 2...14, "pt")
                row("行间距", $cfg.rowGap, 2...14, "pt")
                row("键帽圆角", $cfg.corner, 0...16, "pt")
                row("字号大小", $cfg.fontScale, 0.7...1.5, "x")
                row("左右边距", $cfg.sideInset, 0...16, "pt")
                row("底部留白", $cfg.bottomInset, 0...16, "pt")
            }

            Section {
                Button("恢复默认", role: .destructive) { cfg = KBConfig() }
            } footer: {
                Text("改动即时生效，去键盘上重新调出一次即可看到。")
            }
        }
        .navigationTitle("键盘布局")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cfg) { newValue in
            // 拖一下立刻生效：存本机 + 推给键盘，不用再点「应用到键盘」
            KBConfigStore.saveLocal(newValue)
            ConfigSync.publish(layout: newValue)
        }
    }

    // MARK: - 一行滑杆

    private func row(_ label: String, _ value: Binding<Double>,
                     _ range: ClosedRange<Double>, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(fmt(value.wrappedValue) + unit)
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func fmt(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}

/// 迷你键盘预览：按当前配置实时画出键高、间距、圆角、字号，
/// 内容自动缩放到卡片里，拖滑杆能立刻看出变化。
private struct KBPreview: View {

    let cfg: KBConfig

    private let rows: [[String]] = [
        Array("qwertyuiop").map { String($0) },
        Array("asdfghjkl").map { String($0) },
        Array("zxcvbnm").map { String($0) },
    ]

    var body: some View {
        GeometryReader { geo in
            let rawH = cfg.keyHeight * 3 + cfg.rowGap * 2 + cfg.bottomInset
            let scale = min(1, max(0.2, (geo.size.height - 10) / max(rawH, 1)))
            VStack(spacing: cfg.rowGap * scale) {
                RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .frame(height: 30 * scale)
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: cfg.keyGap * scale) {
                        ForEach(rows[r], id: \.self) { k in
                            RoundedRectangle(cornerRadius: cfg.corner * scale,
                                             style: .continuous)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.25),
                                        radius: 0, x: 0, y: 1)
                                .overlay(
                                    Text(k)
                                        .font(.system(size: 20 * cfg.fontScale * scale))
                                        .foregroundColor(.black))
                        }
                    }
                    .frame(height: cfg.keyHeight * scale)
                }
            }
            .padding(.horizontal, cfg.sideInset * scale)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.82, green: 0.83, blue: 0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}
