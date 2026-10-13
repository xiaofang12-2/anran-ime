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
                KeyEditor(cfg: $cfg)
                    .frame(height: 150)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                              bottom: 8, trailing: 12))
                Button("恢复全部默认键位", role: .destructive) {
                    cfg.keyOverrides = nil
                }
            } header: {
                Text("自定义键位")
            } footer: {
                Text("点上面的按键：可调它的宽度，也可以让它在那一行里左移/右移。改完去键盘重新调出一次就能看到。")
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
            .background(cfg.activeTheme.bgColor)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// 键位编辑器：把三层键位按「应用了宽度/位置覆盖后的最终样子」画出来，
/// 点任意键弹出编辑面板 —— 调宽度、行内左移/右移、恢复该键默认。
/// 数据直接写 cfg.keyOverrides，onChange 自动推给键盘。
struct KeyEditor: View {

    @Binding var cfg: KBConfig
    @State private var editing: KeySpec?

    /// 编辑器里画哪些键：字母三行 + 退格（最常用的部分，太多键小屏点不准）
    private var appliedRows: [[KeySpec]] {
        let base = Array(KeyboardLayout.letterRows(shift: false, swipe: false).prefix(3))
        return KeyOverrideApplier.apply(base, overrides: cfg.keyOverrides)
    }

    var body: some View {
        GeometryReader { geo in
            let rows = appliedRows
            let gap: CGFloat = 4
            let h = geo.size.height
            let keyH = (h - gap * 2) / 3
            VStack(spacing: gap) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(rows[r]) { k in
                            editorKey(k)
                        }
                    }
                    .frame(height: keyH)
                }
            }
        }
        .sheet(item: $editing) { spec in
            KeyEditSheet(spec: spec, cfg: $cfg)
        }
    }

    @ViewBuilder
    private func editorKey(_ k: KeySpec) -> some View {
        let overridden = cfg.keyOverrides?[k.id] != nil
        Button { editing = k } label: {
            Text(k.label)
                .font(.system(size: k.label.count > 1 ? 11 : 15, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(Color(hex: cfg.activeTheme.text))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(hex: cfg.activeTheme.key))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(overridden ? Color(hex: cfg.activeTheme.accent)
                                                         : Color.black.opacity(0.12),
                                              lineWidth: overridden ? 2 : 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1))
        }
        .buttonStyle(.plain)
    }
}

/// 单键编辑面板：宽度滑块 + 左移/右移 + 恢复该键
private struct KeyEditSheet: View {

    let spec: KeySpec
    @Binding var cfg: KBConfig
    @Environment(\.dismiss) private var dismiss

    private var ovBinding: Binding<KeyOverride> {
        Binding {
            cfg.keyOverrides?[spec.id] ?? KeyOverride(weight: nil, shift: 0)
        } set: { v in
            var map = cfg.keyOverrides ?? [:]
            let isDefault = (v.weight == nil || abs(v.weight! - Double(spec.weight)) < 0.01)
                && v.shift == 0
            if isDefault { map.removeValue(forKey: spec.id) } else { map[spec.id] = v }
            cfg.keyOverrides = map.isEmpty ? nil : map
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("按键「\(spec.label)」") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("宽度")
                            Spacer()
                            Text(wText)
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { ovBinding.wrappedValue.weight ?? Double(spec.weight) },
                            set: { ovBinding.wrappedValue.weight = $0 }), in: 0.6...3.0)
                    }
                    Stepper(value: ovBinding.shift, in: -3...3) {
                        HStack {
                            Text("行内位置")
                            Spacer()
                            Text(ovBinding.wrappedValue.shift == 0
                                 ? "默认位置"
                                 : (ovBinding.wrappedValue.shift < 0
                                    ? "左移\(-ovBinding.wrappedValue.shift)格"
                                    : "右移\(ovBinding.wrappedValue.shift)格"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Section {
                    Button("恢复这个键的默认", role: .destructive) {
                        var map = cfg.keyOverrides ?? [:]
                        map.removeValue(forKey: spec.id)
                        cfg.keyOverrides = map.isEmpty ? nil : map
                    }
                } footer: {
                    Text("宽度 1.0 是标准键宽（shift/退格这种宽键有自己的默认值）。改完去键盘重新调出一次即可看到。")
                }
            }
            .navigationTitle("自定义键位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var wText: String {
        let w = ovBinding.wrappedValue.weight ?? Double(spec.weight)
        return String(format: "%.2fx", w)
    }
}
