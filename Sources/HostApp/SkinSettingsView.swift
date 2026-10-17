import SwiftUI
import UniformTypeIdentifiers

/// 皮肤设置页：内置配色 + 导入百度输入法皮肤（.bdi / 改后缀的 .zip）。
/// 改动即时存本机推键盘（ConfigSync 整包），去键盘重新调出一次就能看到。
struct SkinSettingsView: View {

    @State private var cfg = KBConfigStore.current
    @State private var picking = false
    @State private var message = ""
    @State private var messageBad = false
    @State private var busy = false

    var body: some View {
        List {
            Section {
                SkinPreview(theme: cfg.activeTheme)
                    .frame(height: 170)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12,
                                              bottom: 8, trailing: 12))
            } header: {
                Text("当前皮肤：\(cfg.activeTheme.name)")
            }

            Section {
                Button {
                    picking = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入百度输入法皮肤（.bdi）")
                    }
                }
                .disabled(busy)
                if busy {
                    HStack {
                        ProgressView()
                        Text("正在解析皮肤…")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                if !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(messageBad ? .red : .secondary)
                }
            } header: {
                Text("导入皮肤")
            } footer: {
                Text("百度输入法 iOS 的皮肤文件是 .bdi，在百度输入法里收藏的皮肤可以在「我的皮肤」里导出；直接选 .bdi 文件导入即可。配色和背景图能认出来就自动套用。")
            }

            Section("内置配色") {
                ForEach(KBTheme.presets, id: \.name) { t in
                    Button {
                        cfg.theme = t
                        message = "已套用「\(t.name)」"
                        messageBad = false
                    } label: {
                        HStack {
                            ThemeSwatch(theme: t)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(t == KBTheme.classic ? "默认" : "内置")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if cfg.activeTheme.name == t.name &&
                                cfg.activeTheme.bgImage == nil {
                                Image(systemName: "checkmark")
                                    .font(.footnote.bold())
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }

            Section {
                Button("恢复默认皮肤", role: .destructive) {
                    cfg.theme = nil
                    message = "已恢复默认"
                    messageBad = false
                }
            }
        }
        .navigationTitle("皮肤")
        .arListPage()
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: cfg) { newValue in
            KBConfigStore.saveLocal(newValue)
            ConfigSync.publish(layout: newValue)
        }
        .sheet(isPresented: $picking) {
            SkinPicker { data, name in
                importSkin(data, name: name)
            }
        }
    }

    private func importSkin(_ data: Data, name: String) {
        busy = true
        message = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<KBTheme, Error>
            do {
                var theme = try SkinImporter.importSkin(data)
                theme.name = (name as NSString).deletingPathExtension
                result = .success(theme)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let t):
                    cfg.theme = t
                    message = "皮肤「\(t.name)」导入成功，去键盘看看效果"
                    messageBad = false
                case .failure(let e):
                    message = e.localizedDescription
                    messageBad = true
                }
            }
        }
    }
}

/// 文件选择器：选 .bdi / .zip 皮肤包
private struct SkinPicker: UIViewControllerRepresentable {

    let onPick: (Data, String) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var types: [UTType] = [.zip, .archive]
        if let bdi = UTType(filenameExtension: "bdi") { types.append(bdi) }
        if let bds = UTType(filenameExtension: "bds") { types.append(bds) }
        types.append(.data)
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types,
                                               asCopy: true)
        p.allowsMultipleSelection = false
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data, String) -> Void
        init(onPick: @escaping (Data, String) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let d = try? Data(contentsOf: url) {
                onPick(d, url.lastPathComponent)
            }
        }
    }
}

/// 主题小样：一排色块模拟键帽 + 底色
private struct ThemeSwatch: View {
    let theme: KBTheme

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(i == 1 ? Color(hex: theme.special)
                                 : Color(hex: theme.key))
                    .frame(width: 14, height: 22)
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: theme.bg)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
    }
}

/// 皮肤预览：按主题画一个迷你键盘，带背景图
struct SkinPreview: View {

    let theme: KBTheme

    private let rows: [[String]] = [
        Array("qwertyuiop").map { String($0) },
        Array("asdfghjkl").map { String($0) },
        Array("zxcvbnm").map { String($0) },
    ]

    private var bgImage: UIImage? {
        guard let b64 = theme.bgImage, let d = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: d)
    }

    var body: some View {
        ZStack {
            if let img = bgImage {
                GeometryReader { geo in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            }
            VStack(spacing: 4) {
                Text(theme.name)
                    .font(.caption2)
                    .foregroundColor(Color(hex: theme.candidateText))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(rows[r], id: \.self) { k in
                            Text(k.uppercased())
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: theme.text))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(hex: theme.key).opacity(0.96)))
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: theme.bg))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}
