import SwiftUI

/// 「自定义短语」管理页：打触发码直接出内容（如 dz → 地址、sfz → 身份证号）。
///
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
                            Text("第\(p.position)位")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor))
                        }
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
                Text("点条目可编辑，左滑可删除。触发码建议用字母，别用中文。\n"
                     + "「位置」= 命中后排在候选第几位，1 就是排第一位。改动即时生效。")
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
                Section {
                    Stepper(value: $phrase.position, in: 1...9) {
                        HStack {
                            Text("位置")
                            Spacer()
                            Text("第\(phrase.position)位")
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("位置")
                } footer: {
                    Text("命中后排在候选第几位，1 = 排到第一位。")
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
