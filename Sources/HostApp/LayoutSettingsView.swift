import SwiftUI

/// 「键盘布局」编辑器（对标百度输入法皮肤编辑器）：
/// 画布上点任意一个键选中，下面直接改它的 位置 / 宽度 / 高度 / 上滑符号，
/// 可以删掉任何一个键，也可以自己加新键。改完即时推给键盘，
/// 去键盘重新调出一次就能看到，不用再点「应用到键盘」。
struct LayoutSettingsView: View {

    @State private var cfg = KBConfigStore.current
    @State private var selectedID: String?
    @State private var newKeyLabel = ""
    /// 宽高输入框的原始文本（选中键变化时从配置同步，输入过程不被格式化打断）
    @State private var widthInput = ""
    @State private var heightInput = ""

    /// 应用覆盖 + 挂上自定义键之后的最终键位（编辑器预览 = 键盘真实键位）
    private var appliedRows: [[KeySpec]] {
        let base = Array(KeyboardLayout.letterRows(shift: false, swipe: false).prefix(3))
        return KeyOverrideApplier.addCustom(
            KeyOverrideApplier.apply(base, overrides: cfg.keyOverrides),
            keys: cfg.customKeys)
    }

    /// 选中键的（行号, 行内下标）
    private var selectedLocation: (row: Int, idx: Int)? {
        guard let id = selectedID else { return nil }
        for (r, row) in appliedRows.enumerated() {
            if let i = row.firstIndex(where: { $0.id == id }) { return (r, i) }
        }
        return nil
    }

    private var selectedSpec: KeySpec? {
        guard let loc = selectedLocation else { return nil }
        return appliedRows[loc.row][loc.idx]
    }

    var body: some View {
        List {
            Section {
                EditorCanvas(cfg: $cfg, selectedID: selectedID) { spec in
                    selectedID = (selectedID == spec.id) ? nil : spec.id
                }
                .frame(height: 180)
                .listRowInsets(EdgeInsets(top: 8, leading: 10,
                                          bottom: 8, trailing: 10))
            } header: {
                Text("画布")
            }

            if let spec = selectedSpec, let loc = selectedLocation {
                keyEditSection(spec, loc)
            }

            addKeySection

            Section {
                Button("恢复全部默认", role: .destructive) {
                    cfg.keyOverrides = nil
                    cfg.customKeys = nil
                    selectedID = nil
                }
            }
        }
        .navigationTitle("键盘布局")
        .arListPage()
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedID) { _ in syncEditFields() }
        .onChange(of: cfg) { newValue in
            KBConfigStore.saveLocal(newValue)
            ConfigSync.publish(layout: newValue)
        }
    }

    // MARK: - 选中键的属性面板

    @ViewBuilder
    private func keyEditSection(_ spec: KeySpec, _ loc: (row: Int, idx: Int)) -> some View {
        let rowCount = appliedRows[loc.row].count
        Section("按键「\(spec.label)」  第\(loc.row + 1)行") {
            Stepper(value: positionBinding(spec, rowCount: rowCount), in: 1...rowCount) {
                HStack {
                    Text("位置")
                    Spacer()
                    Text("第\(loc.idx + 1)个")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("宽度")
                Spacer()
                TextField("1.0", text: $widthInput)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .onChange(of: widthInput) { s in
                        guard let v = Double(s), v >= 0.6, v <= 3.0 else { return }
                        setOverride(spec) { $0.weight = v }
                    }
            }
            HStack {
                Text("高度")
                Spacer()
                TextField("45", text: $heightInput)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                    .onChange(of: heightInput) { s in
                        guard let v = Double(s), v >= 28, v <= 80 else { return }
                        setOverride(spec) { $0.height = v }
                    }
            }
            HStack {
                Text("上滑符号")
                Spacer()
                TextField("无", text: swipeBinding(spec))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
            }
            Button("恢复这个键的默认", role: .destructive) {
                var map = cfg.keyOverrides ?? [:]
                map.removeValue(forKey: spec.id)
                cfg.keyOverrides = map.isEmpty ? nil : map
            }
            if isCustom(spec) {
                Button("删除这个按键", role: .destructive) {
                    cfg.customKeys = (cfg.customKeys ?? []).filter { $0.id != spec.id }
                    selectedID = nil
                }
            } else {
                Button("删除这个按键", role: .destructive) {
                    setOverride(spec) { $0.deleted = true }
                    selectedID = nil
                }
            }
        }
    }

    // MARK: - 添加按键

    private var addKeySection: some View {
        Section("添加按键") {
            TextField("键帽文字（如 @ 或 呵呵）", text: $newKeyLabel)
                .autocorrectionDisabled()
            Button("添加到第\((selectedLocation?.row ?? 2) + 1)行末尾") {
                let label = newKeyLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return }
                let key = CustomKey(label: label,
                                    row: selectedLocation?.row ?? 2,
                                    swipe: nil, weight: 1)
                cfg.customKeys = (cfg.customKeys ?? []) + [key]
                newKeyLabel = ""
                selectedID = key.id
            }
            .disabled(newKeyLabel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - 覆盖读写

    private func isCustom(_ spec: KeySpec) -> Bool {
        (cfg.customKeys ?? []).contains { $0.id == spec.id }
    }

    /// 改一个键的覆盖；改完等于没改过就清掉（不存垃圾数据）
    private func setOverride(_ spec: KeySpec, _ mutate: (inout KeyOverride) -> Void) {
        var map = cfg.keyOverrides ?? [:]
        var ov = map[spec.id] ?? KeyOverride()
        mutate(&ov)
        if ov.isEmpty(vs: Double(spec.weight)) && !(ov.deleted) {
            map.removeValue(forKey: spec.id)
        } else {
            map[spec.id] = ov
        }
        cfg.keyOverrides = map.isEmpty ? nil : map
    }

    private func positionBinding(_ spec: KeySpec, rowCount: Int) -> Binding<Int> {
        Binding {
            selectedLocation?.idx == nil ? 1 : (selectedLocation!.idx + 1)
        } set: { v in
            setOverride(spec) { $0.pos = min(max(v, 1), rowCount) }
        }
    }

    /// 宽高输入框跟随选中的键（换选中就把配置值填进输入框）
    private func syncEditFields() {
        guard let spec = selectedSpec else {
            widthInput = ""
            heightInput = ""
            return
        }
        widthInput = String(format: "%.2f",
                            cfg.keyOverrides?[spec.id]?.weight ?? Double(spec.weight))
        let h = cfg.keyOverrides?[spec.id]?.height ?? Double(cfg.keyHeight)
        heightInput = "\(Int(h.rounded()))"
    }

    private func swipeBinding(_ spec: KeySpec) -> Binding<String> {
        Binding {
            cfg.keyOverrides?[spec.id]?.swipe ?? spec.swipe ?? ""
        } set: { v in
            setOverride(spec) { $0.swipe = v.isEmpty ? nil : v }
        }
    }
}

// MARK: - 编辑器画布

/// 键位画布：画「应用覆盖后」的最终键位（含自定义键、删除、单键高度），
/// 点键回调给宿主做选中。
private struct EditorCanvas: View {

    @Binding var cfg: KBConfig
    let selectedID: String?
    let onTap: (KeySpec) -> Void

    private var appliedRows: [[KeySpec]] {
        let base = Array(KeyboardLayout.letterRows(shift: false, swipe: false).prefix(3))
        return KeyOverrideApplier.addCustom(
            KeyOverrideApplier.apply(base, overrides: cfg.keyOverrides),
            keys: cfg.customKeys)
    }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let baseH: CGFloat = 42
            let rowHs: [CGFloat] = appliedRows.map { row in
                (row.compactMap { $0.height }.max().map { max($0, baseH) } ?? baseH)
            }
            let totalH = rowHs.reduce(0, +) + gap * CGFloat(max(appliedRows.count - 1, 0))
            let scale = min(1, (geo.size.height - 6) / max(totalH, 1))
            VStack(spacing: gap) {
                // 预览的行数会随滑杆实时变；按下标取行有越界风险（见 KeyboardRootView.keyRows）
                let allRows = appliedRows
                let heights = rowHs
                ForEach(Array(allRows.enumerated()), id: \.offset) { rp in
                    let r = rp.offset
                    let row = rp.element
                    // 行高数组与行数不一定同步到位（预览重算时），缺的就按 1 倍走
                    let rh = heights.indices.contains(r) ? heights[r] : 1.0
                    let unit = (geo.size.width - gap * CGFloat(max(row.count - 1, 0)))
                        / CGFloat(max(row.reduce(0) { $0 + $1.weight }, 0.1))
                    HStack(spacing: gap) {
                        ForEach(row) { k in
                            canvasKey(k, scale: scale,
                                      h: (k.height.map { CGFloat($0) } ?? rh) * scale,
                                      w: unit * k.weight)
                        }
                    }
                    .frame(height: rh * scale, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func canvasKey(_ k: KeySpec, scale: CGFloat, h: CGFloat, w: CGFloat) -> some View {
        let selected = selectedID == k.id
        Button { onTap(k) } label: {
            Text(k.label)
                .font(.system(size: (k.label.count > 1 ? 11 : 15) * scale,
                              weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(Color(hex: cfg.activeTheme.text))
                .frame(width: w, height: h)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(hex: cfg.activeTheme.key))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(selected ? Color(hex: cfg.activeTheme.accent)
                                                        : Color.black.opacity(0.12),
                                              lineWidth: selected ? 2.5 : 0.5))
                        .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1))
        }
        .buttonStyle(.plain)
    }
}
