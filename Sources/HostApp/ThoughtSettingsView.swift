import SwiftUI

/// 「思想库」管理页：建库 → 加关键词 → 填内容。
/// 键盘上点功能栏的思想库图标，输入关键词就能把内容打出去（对标电脑端思想库）。
/// 与其它配置一样，改完点「应用到键盘」走剪贴板交接（见 ConfigSync）。
struct ThoughtSettingsView: View {

    @State private var book = ThoughtStore.current
    @State private var newLibName = ""
    @State private var showNewLib = false
    @State private var message = ""
    @State private var messageBad = false

    var body: some View {
        List {
            Section {
                if book.libraries.isEmpty {
                    Text("还没有思想库，点下面「新建思想库」建一个。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(book.libraries) { lib in
                    NavigationLink(destination: ThoughtLibraryView(book: $book,
                                                                   libraryID: lib.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lib.name)
                                .font(.subheadline.bold())
                            Text("\(lib.items.count) 个关键词")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { book.libraries.remove(atOffsets: $0) }

                Button {
                    newLibName = ""
                    showNewLib = true
                } label: {
                    Label("新建思想库", systemImage: "plus")
                }
            } header: {
                Text("思想库")
            } footer: {
                Text("左滑删除。建好库后进去加关键词和内容，"
                     + "键盘上点思想库图标输入关键词即可上屏。")
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
        .navigationTitle("思想库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNewLib) {
            TextInputSheet(title: "新建思想库",
                           placeholder: "思想库名字",
                           text: $newLibName,
                           confirm: "创建") { createLibrary() }
        }
        .onChange(of: book) { _ in
            ThoughtStore.saveLocal(book)
            message = ""
        }
    }

    private func createLibrary() {
        let name = newLibName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        book.libraries.append(ThoughtLibrary(name: name))
        newLibName = ""
    }

    private func apply() {
        if ConfigSync.publish(thoughts: book) {
            message = "已发送到键盘，去键盘上重新调出一次即可"
            messageBad = false
        } else {
            message = "发送失败，请重试"
            messageBad = true
        }
    }
}

/// 单个思想库：关键词列表 + 加关键词
private struct ThoughtLibraryView: View {

    @Binding var book: ThoughtBook
    let libraryID: String

    @State private var newKeyword = ""
    @State private var showAdd = false
    @State private var draft: ThoughtItem?

    private var index: Int? {
        book.libraries.firstIndex { $0.id == libraryID }
    }

    var body: some View {
        List {
            if let i = index {
                if book.libraries[i].items.isEmpty {
                    Text("还没有关键词，点下面「添加关键词」。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(book.libraries[i].items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.keyword)
                            .font(.subheadline.bold())
                        Text(item.content.isEmpty ? "（还没填内容）" : item.content)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { draft = item }
                }
                .onDelete { book.libraries[i].items.remove(atOffsets: $0) }

                Button {
                    newKeyword = ""
                    showAdd = true
                } label: {
                    Label("添加关键词", systemImage: "plus")
                }
            }
        }
        .navigationTitle(index.map { book.libraries[$0].name } ?? "思想库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            TextInputSheet(title: "添加关键词",
                           placeholder: "关键词",
                           text: $newKeyword,
                           confirm: "添加") { addKeyword() }
        }
        .sheet(item: $draft) { item in
            ThoughtItemEditView(item: item) { saved in
                upsert(saved)
            }
        }
    }

    private func addKeyword() {
        let kw = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty, let i = index else { return }
        book.libraries[i].items.append(ThoughtItem(keyword: kw))
        newKeyword = ""
    }

    private func upsert(_ item: ThoughtItem) {
        guard let i = index,
              let j = book.libraries[i].items.firstIndex(where: { $0.id == item.id })
        else { return }
        book.libraries[i].items[j] = item
    }
}

/// 关键词内部：填内容
private struct ThoughtItemEditView: View {

    @State var item: ThoughtItem
    let onSave: (ThoughtItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("关键词") {
                    TextField("关键词", text: $item.keyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("内容") {
                    TextEditor(text: $item.content)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle(item.keyword.isEmpty ? "关键词" : item.keyword)
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
                    .disabled(item.cleanKeyword.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 通用单行输入弹窗（iOS 15 的 alert 里放不了输入框，用 sheet 顶上）
private struct TextInputSheet: View {

    let title: String
    let placeholder: String
    @Binding var text: String
    let confirm: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                TextField(placeholder, text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm) {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
