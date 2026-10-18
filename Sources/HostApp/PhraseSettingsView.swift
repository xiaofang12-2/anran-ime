import SwiftUI
import UniformTypeIdentifiers

/// 「自定义短语」管理页：打触发码直接出内容（如 kz → 扣字系列）。
///
/// 一块短语 = 一个触发码 + 多行内容：每行就是一条独立候选
/// 第1行排「位置」位 第2行往后依次+1（kz 五行 位置1 → 候选第1~5位）。
/// 同一个码可以配多块 用位置错开不撞车。
/// 支持直接导入搜狗电脑版 / 百度手机版导出的自定义短语文件。
/// 改动即时存本机并推给键盘（见 ConfigSync），不用再点「应用到键盘」。
struct PhraseSettingsView: View {

    @State private var book = PhraseStore.current
    @State private var draft: Phrase?
    @State private var showImporter = false
    @State private var importMsg = ""

    var body: some View {
        List {
            Section {
                if book.items.isEmpty {
                    Text("还没有短语，点下面「添加短语」建一条。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(book.items) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.code)
                                .font(.subheadline.bold())
                            Text(blockBadge(p))
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                        }
                        Text(p.text.replacingOccurrences(of: "\n", with: " / "))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { draft = p }
                }
                .onDelete { book.items.remove(atOffsets: $0) }

                Button {
                    draft = Phrase()
                } label: {
                    Label("添加短语", systemImage: "plus")
                }

                Button {
                    showImporter = true
                } label: {
                    Label("导入短语（搜狗电脑版 / 百度手机版）",
                          systemImage: "square.and.arrow.down")
                }

                if !importMsg.isEmpty {
                    Text(importMsg)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("短语")
            } footer: {
                Text("点条目可编辑，左滑可删除。一个码一块：内容每行就是一条独立候选，按顺序排在候选栏。"
                     + "「位置」= 第1行排在候选第几位，后面的行依次+1；同一个码配多块时用位置错开。改动即时生效。"
                     + "\n导入支持搜狗电脑版 / 百度手机版导出的短语文件（码,位置=内容 或 码=内容），已导入过的不会重复。")
            }
        }
        .navigationTitle("自定义短语")
        .arListPage()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { p in
            PhraseEditView(phrase: p) { saved in
                upsert(saved)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType.data],
                      allowsMultipleSelection: false) { res in
            switch res {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    importMsg = "读取失败：打不开这个文件"
                    return
                }
                let encodings: [String.Encoding] = [.utf8, .utf16, .gb_18030_2000]
                var raw: String?
                for enc in encodings where raw == nil {
                    raw = String(data: data, encoding: enc)
                }
                guard let text = raw else {
                    importMsg = "读取失败：不是文本文件"
                    return
                }
                importText(text)
            case .failure(let err):
                importMsg = "导入失败：\(err.localizedDescription)"
            }
        }
        .onChange(of: book) { newValue in
            // 改一下立刻生效：存本机 + 推给键盘，不用再点「应用到键盘」
            PhraseStore.saveLocal(newValue)
            ConfigSync.publish(phrases: newValue)
        }
    }

    // MARK: 导入

    /// 解析导入文本 与现有条目按（码+位置+内容）去重后合并
    private func importText(_ raw: String) {
        let blocks = PhraseImporter.parse(raw)
        guard !blocks.isEmpty else {
            importMsg = "没认出可导入的短语 检查一下导出的文件"
            return
        }
        var items = book.items
        let existing = Set(items.map { "\($0.cleanCode)|\($0.position)|\($0.text)" })
        var added = 0
        for b in blocks where !existing.contains("\(b.cleanCode)|\(b.position)|\(b.text)") {
            items.append(b)
            added += 1
        }
        if added == 0 {
            importMsg = "文件里的短语都已经在库里了 没有新增"
        } else {
            book.items = items
            importMsg = "导入 \(added) 条 已同步给键盘"
        }
    }

    /// 列表行的角标：几条 + 起始位（单行从第1位就不啰嗦）
    private func blockBadge(_ p: Phrase) -> String {
        var n = 0
        p.text.enumerateLines { line, _ in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        }
        let count = max(n, 1)
        if count == 1 && p.position <= 1 { return "1条" }
        return "\(count)条 从第\(max(1, p.position))位起"
    }

    private func upsert(_ p: Phrase) {
        var items = book.items
        if let i = items.firstIndex(where: { $0.id == p.id }) {
            items[i] = p
        } else {
            items.append(p)
        }
        book.items = items
    }
}

/// 单块短语的编辑弹窗：码 + 多行内容（每行一条）+ 起始候选位
private struct PhraseEditView: View {

    @State var phrase: Phrase
    let onSave: (Phrase) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 内容行数（空行不算）
    private var lineCount: Int {
        var n = 0
        phrase.text.enumerateLines { line, _ in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        }
        return n
    }

    var body: some View {
        NavigationView {
            Form {
                Section("触发码（输入字母）") {
                    TextField("如 kz", text: $phrase.code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("短语内容（每行一条）") {
                    TextEditor(text: $phrase.text)
                        .frame(minHeight: 150)
                        .autocorrectionDisabled()
                    Text(lineCount > 1
                         ? "共 \(lineCount) 行 = \(lineCount) 条候选  依次排在候选栏"
                         : "一行就是一条  粘贴多行就是多条")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Stepper(value: $phrase.position, in: 1...99) {
                        HStack {
                            Text("位置")
                            Spacer()
                            Text("从第\(phrase.position)位开始")
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("位置")
                } footer: {
                    Text("第1行排在候选第\(phrase.position)位  第2行排第\(phrase.position + 1)位  依次往下  "
                         + "同一个码配多块时用位置错开不撞车")
                }
            }
            .navigationTitle(phrase.code.isEmpty ? "添加短语" : "编辑短语")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(phrase)
                        dismiss()
                    }
                    .disabled(phrase.cleanCode.isEmpty || phrase.text.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 导入解析器：适配搜狗电脑版 / 百度手机版导出的自定义短语文本。
///
/// 兼容两种行格式（分号/井号注释、[分节] 行直接跳过 自动去BOM）：
///     kz,1=扣字          ← 编码,位置=内容（搜狗电脑版 / 百度手机版导出格式）
///     kz=扣字            ← 编码=内容 位置按同码出现顺序自动+1
/// 同码同位置后写的覆盖先写的（对齐搜狗行为）；
/// 同码且位置连续的行合并成一块 位置断档就分块（块行为与手输完全一致）。
enum PhraseImporter {

    static func parse(_ raw: String) -> [Phrase] {
        var bomless = raw
        if bomless.hasPrefix("\u{FEFF}") { bomless.removeFirst() }

        // 1) 逐行收集（码 位置 内容）
        var entries: [(code: String, pos: Int, text: String)] = []
        var autoSeq: [String: Int] = [:]
        for rawLine in bomless.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#")
                || line.hasPrefix("[") || line.hasPrefix("---") {
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let head = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let text = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            var code = head
            var pos = 0
            if let comma = head.firstIndex(of: ",") {
                code = String(head[..<comma]).trimmingCharacters(in: .whitespaces)
                pos = Int(head[head.index(after: comma)...]
                    .trimmingCharacters(in: .whitespaces)) ?? 0
            }
            let clean = code.lowercased().filter {
                ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")
            }
            guard !clean.isEmpty else { continue }
            if pos < 1 {
                autoSeq[clean, default: 0] += 1
                pos = autoSeq[clean]!
            }
            entries.append((clean, pos, text))
        }
        guard !entries.isEmpty else { return [] }

        // 2) 同码同位置去重（后写覆盖先写）
        var lastByKey: [String: String] = [:]
        var keyOrder: [String] = []
        for e in entries {
            let k = "\(e.code)|\(e.pos)"
            if lastByKey[k] == nil { keyOrder.append(k) }
            lastByKey[k] = e.text
        }

        // 3) 按码分组 位置连续的段合成一块 断档分块
        var grouped: [String: [(Int, String)]] = [:]
        for k in keyOrder {
            let parts = k.split(separator: "|")
            guard parts.count == 2, let pos = Int(parts[1]),
                  let text = lastByKey[k] else { continue }
            grouped[String(parts[0]), default: []].append((pos, text))
        }
        var blocks: [Phrase] = []
        for (code, list) in grouped {
            var run: [(Int, String)] = []
            func flush() {
                guard !run.isEmpty else { return }
                var p = Phrase()
                p.code = code
                p.text = run.map { $0.1 }.joined(separator: "\n")
                p.position = run[0].0
                blocks.append(p)
                run.removeAll()
            }
            for item in list.sorted(by: { $0.0 < $1.0 }) {
                if let last = run.last, item.0 > last.0 + 1 { flush() }
                run.append(item)
            }
            flush()
        }
        blocks.sort { $0.code == $1.code ? $0.position < $1.position : $0.code < $1.code }
        return blocks
    }
}
