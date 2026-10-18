import SwiftUI

/// 「自定义短语」管理页：打触发码直接出内容（如 kz → 扣字系列）。
///
/// 一块短语 = 一个触发码 + 多行内容：每行就是一条独立候选
/// 第1行排「位置」位 第2行往后依次+1（kz 五行 位置1 → 候选第1~5位）。
/// 同一个码可以配多块 用位置错开不撞车。
/// 改动即时存本机并推给键盘（见 ConfigSync），不用再点「应用到键盘」。
struct PhraseSettingsView: View {

    @State private var book = PhraseStore.current
    @State private var draft: Phrase?

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
            } header: {
                Text("短语")
            } footer: {
                Text("点条目可编辑，左滑可删除。一个码一块：第一行填字母触发码，内容每行就是一条独立候选，按顺序排在候选栏。"
                     + "「位置」= 第1行排在候选第几位，后面的行依次+1；同一个码配多块时用位置错开。改动即时生效。")
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
        .onChange(of: book) { newValue in
            // 改一下立刻生效：存本机 + 推给键盘，不用再点「应用到键盘」
            PhraseStore.saveLocal(newValue)
            ConfigSync.publish(phrases: newValue)
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
