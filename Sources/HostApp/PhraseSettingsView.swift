import SwiftUI

/// 「自定义短语」管理页：打触发码直接出内容（如 dz → 地址、sfz → 身份证号）。
///
/// 与键盘交接同样走剪贴板：改完点「应用到键盘」，键盘下次弹出时接过去。
struct PhraseSettingsView: View {

    @State private var book = PhraseStore.current
    @State private var draft: Phrase?
    @State private var message = ""
    @State private var messageBad = false

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
                        Text(p.code)
                            .font(.subheadline.bold())
                        Text(p.text)
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
                Text("点条目可编辑，左滑可删除。触发码建议用字母，别用中文。")
            }

            Section {
                Button("应用到键盘") { apply() }
            } footer: {
                if message.isEmpty {
                    Text("点「应用到键盘」后，去键盘上重新调出一次即可生效。")
                } else {
                    Text(message)
                        .foregroundColor(messageBad ? .red : .secondary)
                }
            }
        }
        .navigationTitle("自定义短语")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $draft) { p in
            PhraseEditView(phrase: p) { saved in
                upsert(saved)
            }
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
        // 立刻存本机，避免用户没点「应用到键盘」就退出丢改动
        PhraseStore.saveLocal(book)
        message = ""
    }

    private func apply() {
        if ConfigSync.publish(phrases: book) {
            message = "已发送到键盘，去键盘上重新调出一次即可"
            messageBad = false
        } else {
            message = "发送失败，请重试"
            messageBad = true
        }
    }
}

/// 单条短语的编辑弹窗
private struct PhraseEditView: View {

    @State var phrase: Phrase
    let onSave: (Phrase) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("触发码") {
                    TextField("如 dz / sfz", text: $phrase.code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("展开内容") {
                    TextField("如 张三 13800000000 北京市朝阳区", text: $phrase.text)
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
