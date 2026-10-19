import SwiftUI

/// 「自定义短语」管理页：跟思想库一个用法 ——
/// 先建一个「自定义名」点进去 里面才是设置短语的地方。
/// 一块短语 = 一个触发码 + 多行内容：每行就是一条独立候选
/// 第1行排「位置」位 第2行往后依次+1（kz 五行 位置1 → 候选第1~5位）。
/// 同一个码可以配多块 用位置错开不撞车。各组短语键盘全量生效。
/// 支持从剪贴板粘贴导入搜狗电脑版 / 百度手机版格式的短语文本。
/// 改动即时存本机并推给键盘（见 ConfigSync），不用再点「应用到键盘」。
struct PhraseSettingsView: View {

    @State private var book = PhraseStore.current
    @State private var newGroupName = ""
    @State private var showNewGroup = false

    var body: some View {
        List {
            Section {
                ForEach(book.groups) { g in
                    NavigationLink(destination: PhraseGroupView(book: $book,
                                                                groupID: g.id)) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(g.name.isEmpty ? "未命名" : g.name)
                                    .font(.subheadline.bold())
                                Text("\(g.items.count) 块短语")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            book.groups.removeAll { $0.id == g.id }
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }

                Button {
                    newGroupName = ""
                    showNewGroup = true
                } label: {
                    Label("新建自定义", systemImage: "plus")
                }
            } header: {
                Text("自定义")
            }
        }
        .navigationTitle("自定义短语")
        .arListPage()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNewGroup) {
            TextInputSheet(title: "新建自定义",
                           placeholder: "自定义名",
                           text: $newGroupName,
                           confirm: "创建") { createGroup() }
        }
        .onChange(of: book) { newValue in
            // 改一下立刻生效：存本机 + 推给键盘，不用再点「应用到键盘」
            PhraseStore.saveLocal(newValue)
            ConfigSync.publish(phrases: newValue)
        }
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        book.groups.append(PhraseGroup(name: name))
        newGroupName = ""
    }
}

/// 单个自定义：短语条目列表 + 加短语 + 剪贴板导入 + 多选批量删除
private struct PhraseGroupView: View {

    @Binding var book: PhraseBook
    let groupID: String

    @State private var draft: Phrase?
    @State private var importMsg = ""
    @State private var showImportAlert = false
    @State private var importAlertTitle = ""
    @State private var selection = Set<String>()
    @Environment(\.editMode) private var editMode

    private var index: Int? {
        book.groups.firstIndex { $0.id == groupID }
    }

    var body: some View {
        List(selection: $selection) {
            if let i = index {
                Section {
                    ForEach(book.groups[i].items) { p in
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
                        .onTapGesture {
                            if editMode?.wrappedValue.isEditing != true { draft = p }
                        }
                    }
                    .onDelete { book.groups[i].items.remove(atOffsets: $0) }

                    Button {
                        draft = Phrase()
                    } label: {
                        Label("添加短语", systemImage: "plus")
                    }

                    Button {
                        if let raw = UIPasteboard.general.string {
                            importText(raw)
                        } else {
                            importMsg = "剪贴板是空的 先去把短语内容复制过来"
                            importAlertTitle = "导入失败"
                            showImportAlert = true
                        }
                    } label: {
                        Label("从剪贴板导入（搜狗电脑版 / 百度手机版）",
                              systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("短语")
                }
            }
        }
        .navigationTitle(index.map { book.groups[$0].name } ?? "自定义")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                if editMode?.wrappedValue.isEditing == true,
                   let i = index, !book.groups[i].items.isEmpty {
                    Button(allSelected ? "取消全选" : "全选") { toggleSelectAll() }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if editMode?.wrappedValue.isEditing == true && !selection.isEmpty {
                    Button("删除(\(selection.count))") { deleteSelected() }
                        .foregroundColor(.red)
                }
            }
        }
        .onChange(of: editMode?.wrappedValue) { mode in
            if mode?.isEditing != true { selection.removeAll() }
        }
        .sheet(item: $draft) { p in
            PhraseEditView(phrase: p) { saved in
                upsert(saved)
            }
        }
        .alert(importAlertTitle, isPresented: $showImportAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importMsg)
        }
    }

    private func deleteSelected() {
        guard let i = index else { return }
        book.groups[i].items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private var allSelected: Bool {
        guard let i = index else { return false }
        let items = book.groups[i].items
        return !items.isEmpty && selection.count >= items.count
    }

    private func toggleSelectAll() {
        guard let i = index else { return }
        if allSelected {
            selection.removeAll()
        } else {
            selection = Set(book.groups[i].items.map(\.id))
        }
    }

    // MARK: 导入

    /// 解析导入文本 与全库条目按（码+位置+内容）去重后合并进当前组
    private func importText(_ raw: String) {
        guard let i = index else { return }
        let (blocks, skipped) = PhraseImporter.parse(raw)
        guard !blocks.isEmpty else {
            importMsg = "没认出可导入的短语（识别0条）—— 确认复制的是搜狗/百度导出的短语内容"
            importAlertTitle = "导入失败"
            showImportAlert = true
            return
        }
        let existing = Set(book.items.map { "\($0.cleanCode)|\($0.position)|\($0.text)" })
        var added = 0
        for b in blocks where !existing.contains("\(b.cleanCode)|\(b.position)|\(b.text)") {
            book.groups[i].items.append(b)
            added += 1
        }
        if added == 0 {
            importMsg = "识别 \(blocks.count) 块短语 但都已经导入过了 没有新增"
            importAlertTitle = "没有新增"
        } else {
            importMsg = "识别 \(blocks.count) 块（\(skipped) 条跳过）新增 \(added) 块 已同步给键盘"
            importAlertTitle = "导入成功"
        }
        showImportAlert = true
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
        guard let i = index else { return }
        // 编辑已有的按 id 替换；「添加短语」是新 UUID 列表里没有，追加进去
        if let j = book.groups[i].items.firstIndex(where: { $0.id == p.id }) {
            book.groups[i].items[j] = p
        } else {
            book.groups[i].items.append(p)
        }
    }
}

/// 单块短语的编辑弹窗：码 + 多行内容（每行一条）+ 起始候选位
private struct PhraseEditView: View {

    @State var phrase: Phrase
    let onSave: (Phrase) -> Void

    @Environment(\.dismiss) private var dismiss

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
/// 兼容的行格式（分号/井号注释、[分节] 行跳过 自动去BOM）：
///     af,1=安抚               ← 搜狗电脑版：码,位置=内容
///     shq=3,必须宣布你妈属于我  ← 百度手机版：码=位置,内容（位置在等号后逗号前）
///     kz=扣字                 ← 简式：码=内容 位置按同码出现顺序自动+1
///     cao,7操你个…（缺等号）    ← 烂行也救回来 当 码,位置=内容 处理
///     ss,1=#$year…            ← 搜狗时间函数行 跳过不导（咱不认 # 表达式）
/// 位置0（百度表示最前）按第1位算；同码同位置后写的不再覆盖 而是顺延到下一个空位
/// （小防那种同码多组 a=2..9 的文件一条都不丢）；搜狗「码,位置=」后跟多行的长短语整块收进来。
enum PhraseImporter {

    static func parse(_ raw: String) -> ([Phrase], Int) {
        var bomless = raw
        if bomless.hasPrefix("\u{FEFF}") { bomless.removeFirst() }

        var entries: [(code: String, pos: Int, text: String)] = []
        var autoSeq: [String: Int] = [:]
        var skipped = 0
        var multi: (code: String, pos: Int, lines: [String])?   // 搜狗多行收集

        func flushMulti() {
            guard let m = multi else { return }
            multi = nil
            let text = m.lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !text.isEmpty { append(m.code, m.pos, text) }
        }
        func append(_ rawCode: String, _ pos: Int, _ text: String) {
            let clean = rawCode.lowercased().filter {
                ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9")
            }
            guard !clean.isEmpty, !text.isEmpty else { return }
            if pos < 1 {
                autoSeq[clean, default: 0] += 1
                entries.append((clean, autoSeq[clean]!, text))
            } else {
                entries.append((clean, pos, text))
            }
        }

        for rawLine in bomless.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 正在收搜狗多行短语：空行或新条目行才断
            if multi != nil {
                if line.isEmpty {
                    flushMulti()
                    continue
                }
                if isEntryLine(line) { flushMulti() }   // 落下去走正常条目解析
                else {
                    multi!.lines.append(line)
                    continue
                }
            }

            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#")
                || line.hasPrefix("[") || line.hasPrefix("---") {
                continue
            }

            // 缺等号的烂行：码,数字 直接跟内容（如 cao,7操你个…）
            if !line.contains("="), let r = parseNoEqual(line) {
                append(r.0, r.1, r.2)
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let head = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var text = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)

            var code = head
            var pos = 0

            if let comma = head.firstIndex(of: ",") {
                // 搜狗电脑版：码,位置=内容
                code = String(head[..<comma]).trimmingCharacters(in: .whitespaces)
                pos = Int(head[head.index(after: comma)...]
                    .trimmingCharacters(in: .whitespaces)) ?? 0
                if text.isEmpty {
                    // 搜狗多行格式：码,位置= 后面跟着内容行
                    multi = (code, pos, [])
                    continue
                }
            } else if let comma = text.firstIndex(of: ",") {
                // 百度手机版：码=位置,内容 —— 等号后1~2位纯数字+逗号 数字就是位置
                // 位置0=排最前 也认
                let numPart = String(text[..<comma]).trimmingCharacters(in: .whitespaces)
                if numPart.count <= 2, let n = Int(numPart), n >= 0 {
                    let rest = String(text[text.index(after: comma)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty {
                        pos = max(n, 1)
                        text = rest
                    }
                }
            }

            if text.hasPrefix("#") { skipped += 1; continue }   // 搜狗时间函数
            guard !text.isEmpty else { continue }
            append(code, pos, text)
        }
        flushMulti()
        guard !entries.isEmpty else { return ([], skipped) }

        // 同码逐条占位：位置0→第1位 位置被占就顺延到该码已占最大位+1（一条不丢）
        var used: [String: Set<Int>] = [:]
        var lastSlot: [String: Int] = [:]
        var placed: [(code: String, slot: Int, text: String)] = []
        for e in entries {
            var s = e.pos
            if used[e.code]?.contains(s) == true {
                s = (lastSlot[e.code] ?? 0) + 1
            }
            used[e.code, default: []].insert(s)
            lastSlot[e.code] = max(lastSlot[e.code] ?? 0, s)
            placed.append((e.code, s, e.text))
        }

        // 按码分组 槽位连续的合成一块 断档分块
        var grouped: [String: [(Int, String)]] = [:]
        for p in placed { grouped[p.code, default: []].append((p.slot, p.text)) }
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
        return (blocks, skipped)
    }

    /// 正常条目行的样子（多行收集时的断行判据）：宽泛认 码,数字= / 码=数字, / 码=内容
    private static func isEntryLine(_ line: String) -> Bool {
        guard let eq = line.firstIndex(of: "=") else { return false }
        let head = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        if head.contains(",") {
            let parts = head.split(separator: ",")
            return parts.count >= 1 && parts[0].allSatisfy {
                $0.isLetter || $0.isNumber
            } && parts.count == 2 && parts[1].allSatisfy(\.isNumber)
        }
        return !head.isEmpty
    }

    /// 缺等号行：码,数字+内容 → (码, 位置, 内容)
    private static func parseNoEqual(_ line: String) -> (String, Int, String)? {
        guard let comma = line.firstIndex(of: ",") else { return nil }
        let code = String(line[..<comma]).trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        let rest = line[line.index(after: comma)...]
        let digits = rest.prefix(while: { $0.isNumber })
        guard digits.count >= 1, digits.count <= 2,
              let pos = Int(digits), pos >= 1
        else { return nil }
        let text = String(rest.dropFirst(digits.count))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return (code, pos, text)
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
