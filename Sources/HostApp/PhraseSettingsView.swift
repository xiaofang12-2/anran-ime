import SwiftUI

/// 「自定义短语」管理页：打触发码直接出内容（如 dz → 地址、sfz → 身份证号）。
///
/// 同一个触发码可以配多条 打码时依次排在候选栏随你挑。
/// 内容支持多行 一行一句 发出去就是多行；「位置」= 多行内容从第几行开始输出。
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
                            if p.position > 1 {
                                Text("从第\(p.position)行开始")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.accentColor))
                            }
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
                Text("点条目可编辑，左滑可删除。触发码建议用字母，别用中文；同一个码可以配多条，打码时依次排在候选栏。\n"
                     + "内容支持多行，一行一句；「位置」= 多行内容从第几行开始输出，比如选 2 就跳过第 1 行。改动即时生效。")
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

/// 单条短语的编辑弹窗：码 + 多行内容 + 起始行
private struct PhraseEditView: View {

    @State var phrase: Phrase
    let onSave: (Phrase) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 内容按行拆（空行不算一行）
    private var lineCount: Int {
        var n = 0
        phrase.text.enumerateLines { line, _ in
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        }
        return n
    }

    /// 起始行跟随内容行数：删了行就自动收回来，不让它悬在超出的位置
    private var posBinding: Binding<Int> {
        Binding {
            min(phrase.position, max(lineCount, 1))
        } set: { phrase.position = $0 }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("触发码（输入字母）") {
                    TextField("如 dz / sfz", text: $phrase.code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("短语内容（支持多行 一行一句）") {
                    TextEditor(text: $phrase.text)
                        .frame(minHeight: 130)
                        .autocorrectionDisabled()
                    Text(lineCount > 1
                         ? "共 \(lineCount) 行  发出去就是多行内容"
                         : "可以粘贴多行内容  一行就是一句")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Stepper(value: posBinding, in: 1...max(lineCount, 1)) {
                        HStack {
                            Text("位置")
                            Spacer()
                            Text("从第\(posBinding.wrappedValue)行开始")
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(lineCount < 2)
                } header: {
                    Text("位置")
                } footer: {
                    Text(lineCount < 2
                         ? "内容至少两行才有起始行可选  多行内容时选 2 就从第 2 行开始输出"
                         : "多行内容从第几行开始输出  比如选 2 就跳过第 1 行  从第 2 行开始上屏")
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
                        var p = phrase
                        p.position = posBinding.wrappedValue
                        onSave(p)
                        dismiss()
                    }
                    .disabled(phrase.cleanCode.isEmpty || phrase.text.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
