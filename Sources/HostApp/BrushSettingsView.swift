import SwiftUI

/// 「刷天帝」管理页：建文本 → 填内容（不限任何内容，一行一句）。
/// 键盘里选中文本，点开启就自动逐行输出（比思想库更快）。
/// 改动即时存本机并推给键盘（见 ConfigSync），不用再点「应用到键盘」。
struct BrushSettingsView: View {

    @State private var book = BrushStore.current
    @State private var newName = ""
    @State private var showNew = false
    @State private var draft: BrushItem?

    var body: some View {
        List {
            Section {
                ForEach(book.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.bold())
                        Text(item.content.isEmpty ? "（还没填内容）" : item.content)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { draft = item }
                }
                .onDelete { book.items.remove(atOffsets: $0) }

                Button {
                    newName = ""
                    showNew = true
                } label: {
                    Label("新建文本", systemImage: "plus")
                }
            } header: {
                Text("刷天帝")
            } footer: {
                Text("内容不限任何文字，一行一句。键盘里选中文本点开启即自动逐行输出。")
            }
        }
        .navigationTitle("刷天帝")
        .arListPage()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNew) {
            BrushNameSheet(name: $newName) {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                book.items.append(BrushItem(name: n))
                newName = ""
            }
        }
        .sheet(item: $draft) { item in
            BrushItemEditView(item: item) { saved in
                if let i = book.items.firstIndex(where: { $0.id == saved.id }) {
                    book.items[i] = saved
                }
            }
        }
        .onChange(of: book) { newValue in
            BrushStore.saveLocal(newValue)
            ConfigSync.publish(brushes: newValue)
        }
    }
}

/// 编辑单条刷天帝文本（名称 + 内容，内容不限）
private struct BrushItemEditView: View {

    @State var item: BrushItem
    let onSave: (BrushItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("文本名称") {
                    TextField("名称", text: $item.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("内容（不限内容，一行一句）") {
                    TextEditor(text: $item.content)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle(item.name.isEmpty ? "文本" : item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(item)
                        dismiss()
                    }
                    .disabled(item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 命名弹窗（iOS 15 的 alert 放不了输入框，用 sheet 顶上）
private struct BrushNameSheet: View {

    @Binding var name: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                TextField("文本名称", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle("新建文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
