import SwiftUI
import UIKit

/// 键盘界面
///
/// 纯本地：没有登录墙、没有账号、没有授权校验，打开即打字。
struct KeyboardRootView: View {

    let controller: KeyboardViewController


    // 输入状态
    @State private var composing = ""                    // 拼音串（双拼模式下是双拼键串）
    @State private var enginePy = ""                     // 喂给引擎的全拼（双拼模式下是解码结果）
    @State private var candidates: [PinyinCandidate] = []
    /// 当前候选栏展示的是「上屏联想」而不是拼音候选（点选行为不同）
    @State private var assocMode = false
    @State private var layer: KBLayer = .letters
    @State private var shiftOn = false
    @State private var capsLock = false
    @State private var lastShiftTap = Date.distantPast
    @State private var lastSpaceTap = Date.distantPast
    /// 最近一次上屏的内容（词或思想库整句 + 是否思想库发的）：
    /// 退格上滑「回退」用 —— 直接从文本框删掉，不还原拼音；
    /// 思想库模式下连面板输入框一起清
    @State private var lastOutput: (text: String, thought: Bool)?
    /// 配置/短语从主程序接过来后 +1，逼界面按新尺寸重画
    @State private var cfgRev = 0
    /// 回车键文案：跟宿主 App 的 returnKeyType 走（聊天软件显示「发送」）
    @State private var returnLabel = "换行"
    /// 上一次从本地链路重拉配置的时间（起词时节流重拉用）
    @State private var lastSyncAt = Date.distantPast
    // 顶部功能栏 / 浮层面板
    @State private var panel: KBPanel = .none
    @State private var expandedCandidates = false          // 展开候选栏（网格）
    @State private var thoughtQuery = ""
    @State private var thoughtComposing = ""                 // 面板里的拼音串
    @State private var thoughtCands: [PinyinCandidate] = []
    @State private var thoughtBusy = false                   // 逐字上屏进行中
    @State private var thoughtQueue: [String] = []           // 排队待发：上一句还在逐字上屏时按回车 先排这里
    @State private var clipboardText = ""
    @State private var thoughts: [ThoughtItem] = []

    // 刷天帝
    @State private var brushTexts: [BrushItem] = []
    @State private var brushSelected = 0
    @State private var brushBusy = false
    @State private var brushQueue: [String] = []
    @State private var brushSpeed: Int = {
        let k = "anran_brush_speed"
        if UserDefaults.standard.object(forKey: k) != nil {
            return UserDefaults.standard.integer(forKey: k)
        }
        return IMESettingsStore.current.brushSpeed
    }()

    /// 每个关键词各自记住输出到第几行（永久书签）的内存镜像。
    /// 用 @State 而不直接读 UserDefaults：回车一按预览条立刻跳到下一句，
    /// 不用等整句逐字发完那一下 @State 变动才重画（「预览跟着回车走」就是它）。
    /// UserDefaults 落盘：面板开关、键盘收弹、中途调用别的关键词、
    /// 甚至扩展进程被系统杀掉重开，回到那个词都接着上次那句出。
    @State private var thoughtProgress: [String: Int] = [:]

    private func loadThoughtProgress() {
        thoughtProgress = (UserDefaults.standard.dictionary(forKey: "anran_thought_progress")
                           as? [String: Int]) ?? [:]
    }

    private func thoughtLineIndex(_ key: String) -> Int { thoughtProgress[key] ?? 0 }

    private func setThoughtProgress(_ id: String, _ value: Int) {
        thoughtProgress[id] = value
        var d = (UserDefaults.standard.dictionary(forKey: "anran_thought_progress")
                 as? [String: Int]) ?? [:]
        d[id] = value
        UserDefaults.standard.set(d, forKey: "anran_thought_progress")
    }

    /// 最后一次成功调用的关键词文本（也持久化）：
    /// 面板清空后连按回车接着出下一句；面板关了再开、进程重启都还认。
    private var activeThoughtKey: String? {
        let v = UserDefaults.standard.string(forKey: "anran_thought_active")
        return (v?.isEmpty == false) ? v : nil
    }

    private func setActiveThought(_ kw: String) {
        UserDefaults.standard.set(kw, forKey: "anran_thought_active")
    }

    var body: some View {
        keyboard
        .padding(.horizontal, KBMetrics.sideInset)
        .padding(.top, KBMetrics.topInset)
        .padding(.bottom, KBMetrics.bottomInset)
        // 皮肤背景：纯色打底 + 可选的皮肤图（导入百度皮肤带过来的）铺满全屏
        .background {
            // 读一下 cfgRev：配置（主题/键位）从主程序接过来后 +1，逼这层重画
            let _ = cfgRev
            ZStack {
                KBMetrics.themeBgColor
                if let img = KBMetrics.themeBgImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            _ = cfgRev
            check()
        }
        // 键盘每次弹出（宿主 viewWillAppear 广播）都重拉配置：
        // onAppear 在扩展进程存活期间只触发一次，不补这一下，主程序改的
        // 自定义短语/布局/设置不会同步过来。
        .onReceive(NotificationCenter.default.publisher(for: .anranKeyboardWillAppear)) { _ in
            check()
        }
        // 秒同步门铃：主 app 改完设置/短语/思想库按铃，键盘直连它的回环
        // server 拉整包（LocalSyncLink，不碰剪贴板）。键盘正开着也立刻
        // 落盘刷新，不用等收起重弹、不用等服务器往返。
        .onReceive(NotificationCenter.default.publisher(for: .anranLocalBusRing)) { _ in
            pullLocalIfNew()
        }
    }

    // MARK: - 正常键盘

    private var keyboard: some View {
        VStack(spacing: KBMetrics.rowGap) {
            topBar
            if panel == .brush {
                // 刷天帝：替换 26 键区域为控制面板，高度不变
                BrushControlPanel(
                    texts: brushTexts,
                    selectedIdx: $brushSelected,
                    speed: $brushSpeed,
                    isRunning: brushBusy,
                    onToggle: toggleBrushOutput,
                    onClose: closeBrushPanel)
            } else {
                panels
                expandedGrid
                keyRows
            }
        }
        // 候选空了（上完屏/删光）展开栏自动收起，不留一块空白
        .onChange(of: candidates) { _ in syncExpandAuto() }
        .onChange(of: thoughtCands) { _ in syncExpandAuto() }
    }

    /// 顶栏一行装下 LOGO + 候选词 + 功能图标（学百度，不再分两栏）
    /// 正在打拼音时功能图标整组让位，候选词拉满整行
    /// （思想库面板里打关键词/拼音同样让位 —— 显示什么就发什么）
    /// 单独拆出来：整棵 TopBar 表达式太肥，塞在 keyboard 里类型检查器直接超时
    /// （「unable to type-check this expression in reasonable time」）。
    private var topBar: some View {
        // 三元提到调用外：参数表达式越单纯，类型检查器越不容易超时
        // 双拼已移除：全拼键盘不再显示方案角标
        // 刷天帝模式：26 键区域替换为控制面板（速度 + 文本选择 + 开启）
        return TopBar(thoughtOn: panel == .thought,
       brushOn: panel == .brush,
               clipboardOn: panel == .clipboard,
               typing: typing,
               composing: panel == .thought ? (thoughtQuery + thoughtComposing) : composing,
               candidates: panel == .thought ? thoughtCands : candidates,
               onPick: panel == .thought ? pickThought : pick,
               onForget: panel == .thought ? { _ in } : forget,
               onPin: panel == .thought ? { _ in } : pin,
               expandOn: expandedCandidates,
               onToggleExpand: toggleExpandCandidates,
               onClipboard: toggleClipboard,
               onThought: toggleThought,
       onThoughtLongPress: { controller.openHost("thoughts") },
       onBrush: toggleBrush,
       onBrushLongPress: { controller.openHost("brush") },
       onCollapse: { controller.dismissKeyboardNow() })
    }

    /// 剪贴板 / 思想库面板（互斥出现）
    private var panels: some View {
        Group {
            if panel == .clipboard {
                ClipboardPanel(text: clipboardText,
                               onInsert: insertClipboard,
                               onClose: closePanel)
            }
            if panel == .thought {
                ThoughtPanel(query: thoughtQuery,
                             composing: thoughtComposing,
                             preview: thoughtPreview,
                             previewHit: thoughtPreviewHit,
                             onClose: closeThoughtPanel)
            }
        }
    }

    /// 展开候选栏：单行候选一键铺成网格（思想库模式下点词落进面板输入框）
    private var expandedGrid: some View {
        Group {
            if expandedCandidates {
                CandidateGridPanel(candidates: panel == .thought ? thoughtCands : candidates,
                                   onPick: panel == .thought ? pickThought : pick)
            }
        }
    }

    /// 字母/数字/符号各行按键
    ///
    /// rows 是计算属性，切层（ABC/123/符号）或主程序改布局下发 cfgRev
    /// 都会让它变行数。遍历 indices 再 rows[i] 取行，渲染途中一变就
    /// 越界崩 —— 扩展被打死的直接表现就是「点一下键输入法就跳走了」。
    /// 改成一行一行的值快照，闭包只用捕获到的那一行。
    private var keyRows: some View {
        let all = Array(rows.enumerated())
        return ForEach(all, id: \.offset) { pair in
            KeyRow(keys: pair.element,
                   onKey: handle,
                   onSwipe: swipe,
                   onDeleteClear: clearComposing,
                   onSpaceMove: { controller.moveCursor($0) },
                   onLongPress: longPress)
        }
    }

    /// 功能栏（顶栏右侧图标组）隐藏规则：正在输入就让位 ——
    /// 普通打字看拼音串，思想库模式看面板里的关键词/拼音串，打完自动恢复。
    private var typing: Bool {
        panel == .thought
            ? (!thoughtQuery.isEmpty || !thoughtComposing.isEmpty)
            : (!composing.isEmpty || assocMode)
    }

    // MARK: - 功能栏 / 面板

    /// 面板开合：把多出来的高度报给键盘容器，否则展开的行会被裁掉
    private func setPanel(_ p: KBPanel) {
        panel = p
        applyExtraHeight()
        syncExpandAuto()
    }

    /// 当前额外总高度 = 面板（剪贴板/思想库）+ 展开候选栏，两块可叠加
    private func applyExtraHeight() {
        var extra: CGFloat = 0
        switch panel {
        case .none: break
        case .clipboard: extra = KBMetrics.panelHeight + KBMetrics.rowGap
        // 思想库面板：输入框面板（thoughtPanelHeight 已含真实高度）+ 顶层多一个间隔
        case .thought: extra = KBMetrics.thoughtPanelHeight + KBMetrics.rowGap
        // 刷天帝：替换 26 键区域，不额外加高
        case .brush: break
        }
        if expandedCandidates {
            extra += KBMetrics.candidatePanelHeight + KBMetrics.rowGap
        }
        controller.setExtraHeight(extra)
    }

    /// 展开候选栏开合
    private func toggleExpandCandidates() {
        expandedCandidates.toggle()
        applyExtraHeight()
    }

    /// 候选空了（上完屏/删光/切面板）展开栏自动收起
    private func syncExpandAuto() {
        guard expandedCandidates else { return }
        let list = panel == .thought ? thoughtCands : candidates
        if list.isEmpty {
            expandedCandidates = false
            applyExtraHeight()
        }
    }

    private func toggleClipboard() {
        if panel == .clipboard {
            setPanel(.none)
        } else {
            clipboardText = Self.visibleClipboard()
            setPanel(.clipboard)
        }
    }

    /// 剪贴板面板显示用户自己复制的东西，直接透出即可
    private static func visibleClipboard() -> String {
        UIPasteboard.general.string ?? ""
    }

    // MARK: - 刷天帝

    /// 刷天帝面板：替换 26 键区域，提供速度拉杆 + 文本选择 + 开启按钮
    private func toggleBrush() {
        if panel == .brush {
            closeBrushPanel()
        } else {
            pullSettings()
            brushTexts = BrushStore.current.items
            if brushSelected >= brushTexts.count { brushSelected = 0 }
            setPanel(.brush)
        }
    }

    private func closeBrushPanel() {
        brushBusy = false
        brushQueue = []
        setPanel(.none)
    }

    /// 开启/暂停刷天帝输出
    private func toggleBrushOutput() {
        if brushBusy {
            brushBusy = false
            brushQueue = []
            return
        }
        guard !brushTexts.isEmpty, brushSelected < brushTexts.count else { return }
        let content = brushTexts[brushSelected].content
        let lines = brushContentLines(content)
        guard !lines.isEmpty else { return }
        brushQueue = lines
        brushBusy = true
        startNextBrushLine()
    }

    /// 刷天帝内容按行拆（显式处理所有换行符，保证粘贴的两句话不糊成一行）
    private func brushContentLines(_ content: String) -> [String] {
        splitContentLines(content)
    }

    /// 统一的按行拆内容：显式处理 \n / \r\n / \r / U+2028 / U+2029，
    /// 任何来源（微信/网页/备忘录）粘进来的多行内容都一句是一句，绝不糊成一行。
    private func splitContentLines(_ content: String) -> [String] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        return normalized.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 逐行输出：整句上屏（sendInstant，不逐字），
    /// 句间间隔取面板拉杆的 brushSpeed —— 拉杆实时生效，比思想库更快。
    private func startNextBrushLine() {
        guard brushBusy, !brushQueue.isEmpty else {
            brushBusy = false
            return
        }
        let line = brushQueue.removeFirst()
        controller.sendInstant(line, speedMs: brushSpeed) {
            if brushBusy && !brushQueue.isEmpty {
                startNextBrushLine()
            } else if brushQueue.isEmpty {
                brushBusy = false
            }
        }
    }

    private func toggleThought() {
        if panel == .thought {
            closeThoughtPanel()
        } else {
            // 点图标算用户手势，这时候读一次主程序下发的最新配置（思想库/短语），
            // 免得刚在设置里加完关键词、切回键盘还调不出内容。
            pullSettings()
            thoughtQuery = ""
            thoughtComposing = ""
            thoughtCands = []
            UserDefaults.standard.set(true, forKey: "anran_thought_panel_on")
            setPanel(.thought)
        }
    }

    private func closePanel() {
        setPanel(.none)
    }

    /// 主动关掉思想库面板：这一轮的关键词记忆清空 下次打开从头开始。
    /// 键盘收起再弹出 / 扩展进程被杀重开都不算关 —— 面板和进度都还原 接着上次那句走。
    private func closeThoughtPanel() {
        UserDefaults.standard.set(false, forKey: "anran_thought_panel_on")
        clearThoughtMemory()
        setPanel(.none)
    }

    private func clearThoughtMemory() {
        UserDefaults.standard.removeObject(forKey: "anran_thought_progress")
        UserDefaults.standard.removeObject(forKey: "anran_thought_active")
        thoughtProgress = [:]
    }

    /// 面板输入框里当前显示的原文：已落定的内容 + 还没落定的拼音串。
    /// 「显示什么就发什么」—— 不再用引擎首选兜底，免得打的字母被偷偷变成汉字。
    private var panelText: String {
        (thoughtQuery + thoughtComposing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 面板原文精确命中的**全部**关键词条目（跨库、同名都收）。
    /// 以前键盘只认「使用中」那一本库，其他库的关键词全调不出来
    /// （「骂我1 调不了」就是它）—— 现在所有库所有关键词全通。
    private var exactHits: [ThoughtItem] {
        let t = panelText.lowercased()
        guard !t.isEmpty else { return [] }
        return thoughts.filter { $0.cleanKeyword.lowercased() == t }
    }

    /// 一个关键词（跨库同名合并）的全部内容行，按库顺序拼成一列逐句出
    private func mergedLines(for kw: String) -> [String] {
        thoughts.filter { $0.cleanKeyword.lowercased() == kw }
            .flatMap { thoughtContentLines($0.content) }
    }

    private func progressKey(_ kw: String) -> String { "kw:" + kw.lowercased() }

    private func insertClipboard(_ text: String) {
        controller.commit(text)
        closePanel()
    }

    /// 思想库面板展开时，字母键喂给面板的输入框（键盘扩展里没法再弹系统键盘，
    /// 所以面板的输入只能由键盘自己的键来喂 —— 跟百度翻译框一个道理）。
    /// 字母先进拼音串，候选栏里选汉字落进输入框；回车 = 命中内容逐行上屏。
    private func handleThoughtKey(_ spec: KeySpec) {
        switch spec.action {
        case .letter(let c):
            thoughtComposing += c
            refreshThoughtCands()
        case .text(let t):
            thoughtQuery += t
            thoughtComposing = ""
            thoughtCands = []
        case .backspace:
            if !thoughtComposing.isEmpty {
                thoughtComposing.removeLast()
                refreshThoughtCands()
            } else if !thoughtQuery.isEmpty {
                thoughtQuery.removeLast()
            }
        case .space:
            if !thoughtComposing.isEmpty {
                commitThoughtComposing()
            } else {
                thoughtQuery += " "
            }
        case .ret:
            // 回车 = 出内容：命中关键词出下一句（连按回车逐句推进），
            // 没命中就把面板里打的原文原样逐字送出去
            enqueueThought()
        case .globe:
            controller.advanceToNextInputMode()
        case .toLayer(let l):
            layer = l
        default:
            break
        }
    }

    private func refreshThoughtCands() {
        if thoughtComposing.isEmpty {
            thoughtCands = []
            return
        }
        // 思想库面板里打拼音同样吃双拼解码（用户在哪儿都会用同一套方案）
        let py = thoughtComposing
        thoughtCands = py.isEmpty ? [] : InputEngine.shared.candidates(for: py)
    }

    /// 候选栏里点汉字：落进思想库输入框
    private func pickThought(_ c: PinyinCandidate) {
        guard !c.literal else { return }
        thoughtQuery += c.word
        thoughtComposing = ""
        thoughtCands = []
    }

    /// 把面板拼音串按首选候选落进输入框
    private func commitThoughtComposing() {
        guard let best = thoughtCands.first(where: { !$0.literal }) else {
            thoughtComposing = ""
            thoughtCands = []
            return
        }
        pickThought(best)
    }

    /// 回车/发送，三条路：
    ///   1. 原文精确命中关键词 → 输出关键词内容（关键词本身永远不上屏，发送即清空面板）；
    ///   2. 不是关键词且面板有内容 → 面板里显示的原文原样逐字送出；
    ///   3. 面板是空的 → 空手回车接着出激活关键词的下一句（进度跟着关键词走）。
    /// 连按回车逐句推进；中途在面板里输别的内容（不回车）不影响进度，
    /// 改回关键词接着出下一句，不会从头再来。一轮出完就停（不循环），
    /// 重新输入关键词回车才从头再来。
    private func enqueueThought() {
        let text = panelText
        if let kw = exactHits.first?.cleanKeyword {
            setActiveThought(kw)
            clearThoughtInput()
            let lines = mergedLines(for: kw)
            guard !lines.isEmpty else { return } // 预览条会提示「这个关键词还没有内容」
            let key = progressKey(kw)
            let idx = thoughtLineIndex(key)
            if idx >= lines.count {
                // 这轮已出完：重新输入关键词 = 从头再来
                setThoughtProgress(key, 1)
                offerThoughtLine(lines[0])
            } else {
                setThoughtProgress(key, idx + 1)
                offerThoughtLine(lines[idx])
            }
        } else if !text.isEmpty {
            // 没命中关键词：原文原样送出（以前这里会被模糊匹配截胡，啥也发不出去）
            clearThoughtInput()
            offerThoughtLine(text)
        } else if let kw = activeThoughtKey {
            // 空手回车：接着出激活关键词的下一句
            let lines = mergedLines(for: kw)
            guard !lines.isEmpty else { return }
            let key = progressKey(kw)
            let idx = thoughtLineIndex(key)
            guard idx < lines.count else { return } // 出完了：空手回车不重出
            setThoughtProgress(key, idx + 1)
            offerThoughtLine(lines[idx])
        }
    }

    /// 关键词内容按行拆（去空行去首尾空白）
    /// 走 splitContentLines：显式处理所有换行符，一句是一句，绝不叠成一行。
    private func thoughtContentLines(_ content: String) -> [String] {
        splitContentLines(content)
    }

    /// 尾巴：开启后思想库发出去的每句尾部带设置的符号。
    /// 尾部已有任何符号（Unicode 标点/符号类全认）→ 不重复带；
    /// 尾部是空格 → 替换成尾巴；其他 → 直接补上。
    private func tailApplied(_ line: String) -> String {
        let s = IMESettingsStore.current
        guard s.tailEnabled, !s.tailSymbol.isEmpty, !line.isEmpty else { return line }
        var t = line
        while let last = t.last, last.isWhitespace { t.removeLast() }
        guard let last = t.last else { return line }
        return isSymbolChar(last) ? t : t + s.tailSymbol
    }

    /// 符号判定：Unicode 标点类与符号类全算（中英文标点 数学/货币/装饰符号都拦）
    private func isSymbolChar(_ c: Character) -> Bool {
        c.unicodeScalars.contains { sc in
            switch sc.properties.generalCategory {
            case .otherPunctuation, .openPunctuation, .closePunctuation,
                 .initialPunctuation, .finalPunctuation, .dashPunctuation,
                 .connectorPunctuation, .mathSymbol, .currencySymbol,
                 .modifierSymbol, .otherSymbol:
                return true
            default:
                return false
            }
        }
    }

    /// 一句进发送通道：忙就排队，闲就直接开始逐字上屏
    private func offerThoughtLine(_ line: String) {
        let out = tailApplied(line)
        if thoughtBusy {
            thoughtQueue.append(out)
        } else {
            startThoughtLine(out)
        }
    }

    private func startThoughtLine(_ line: String) {
        let speed = IMESettingsStore.current.outputSpeed
        thoughtBusy = true
        lastOutput = (line, true)
        // KeyboardRootView 是 struct，@State 本身引用存储，闭包直捕即可
        controller.sendTypewriter(line, speedMs: speed) {
            thoughtBusy = false
            if !thoughtQueue.isEmpty {
                let next = thoughtQueue.removeFirst()
                startThoughtLine(next)
            }
        }
    }

    /// 清空思想库面板的输入（关键词/拼音串/候选）
    private func clearThoughtInput() {
        thoughtQuery = ""
        thoughtComposing = ""
        thoughtCands = []
    }

    /// 预览条是否处于「命中待输出」状态（决定文案深浅）
    private var thoughtPreviewHit: Bool {
        if !exactHits.isEmpty { return true }
        return panelText.isEmpty && activeThoughtKey != nil
    }

    /// 预览条文案：下一条回车会输出哪一句，按每个关键词自己的进度算
    private var thoughtPreview: String {
        if let kw = exactHits.first?.cleanKeyword { return thoughtPreviewFor(kw) }
        if panelText.isEmpty {
            if let kw = activeThoughtKey { return thoughtPreviewFor(kw) }
            return "输入关键词 回车逐句输出"
        }
        return "未命中 回车原样发送"
    }

    private func thoughtPreviewFor(_ kw: String) -> String {
        let lines = mergedLines(for: kw)
        guard !lines.isEmpty else { return "这个关键词还没有内容" }
        let idx = thoughtLineIndex(progressKey(kw))
        if idx >= lines.count { return "本轮已出完 重新输入关键词从头再来" }
        return "下一句：" + lines[idx]
    }

    private var rows: [[KeySpec]] {
        let base = KeyboardLayout.rows(layer: layer,
                                       shift: shiftOn || capsLock)
        let applied = KeyOverrideApplier.apply(base, overrides: KBMetrics.cfg.keyOverrides)
        // 用户自己加的按键挂到行尾
        let withCustom = KeyOverrideApplier.addCustom(applied, keys: KBMetrics.cfg.customKeys)
        guard returnLabel != "换行" else { return withCustom }
        // 回车键文案换成宿主 App 要的那个（发送 / 搜索 / 前往…）
        return withCustom.map { row in
            row.map { spec in
                guard case .ret = spec.action else { return spec }
                return KeySpec(spec.id, returnLabel, spec.weight, spec.action,
                               special: spec.special, popup: spec.popup,
                               active: spec.active, swipe: spec.swipe,
                               symbol: spec.symbol, height: spec.height)
            }
        }
    }

    /// 长按层切换键（123 / ABC）= 切输入法。
    /// 参考图的底行只有「123 / 空格 / 回车」三个键、没有地球键，
    /// 但 iOS 必须留一个切回系统键盘的入口，就藏在层切换键的长按里。
    private func longPress(_ spec: KeySpec) {
        guard case .toLayer = spec.action else { return }
        commitComposing()
        controller.advanceToNextInputMode()
    }

    /// 回车键文案：跟宿主 App 的 returnKeyType 走，和系统键盘一致
    private func refreshReturnLabel() {
        let label: String
        switch controller.textDocumentProxy.returnKeyType {
        case .send: label = "发送"
        case .search, .google, .yahoo: label = "搜索"
        case .go: label = "前往"
        case .next: label = "下一项"
        case .done: label = "完成"
        case .join: label = "加入"
        case .route: label = "路线"
        case .continue: label = "继续"
        case .emergencyCall: label = "紧急呼叫"
        default: label = "换行"
        }
        if label != returnLabel { returnLabel = label }
    }

    // MARK: - 按键分发

    private func handle(_ spec: KeySpec) {
        if panel == .thought { handleThoughtKey(spec); return }
        // 联想态下任何新按键都先收掉联想栏（字母键随后由 refresh 重算候选）
        clearAssociates()
        switch spec.action {
        case .letter(let c):
            // 只有「拼音串是空的、且手动按了 ⇧ / 大写锁」才把字母当英文直接上屏。
            // 只要有拼音串在，shift 一律不影响 —— 中文拼音本来就小写，
            // 这样即使 shift 被误点亮，也绝不会把字母吐进宿主输入框。
            if (shiftOn || capsLock) && composing.isEmpty {
                controller.insert(c.uppercased())
                candidates = []
                if shiftOn && !capsLock { shiftOn = false }
            } else {
                // 起一个新词前顺手重拉一次配置：主程序刚改的自定义短语/思想库
                // 立刻就能用上，不用等键盘重新弹出。节流 1.5 秒，别每敲一下都读剪贴板。
                if composing.isEmpty {
                    let now = Date()
                    if now.timeIntervalSince(lastSyncAt) > 1.5 {
                        lastSyncAt = now
                        pullSettings()
                    }
                }
                composing += c
                refresh()
            }

        case .text(let t):
            commitComposing()
            controller.insert(t)
            candidates = []
            if layer != .letters { layer = .letters }
            autoCap(after: t)
            InputEngine.shared.clearContext()

        case .shift:
            tapShift()

        case .backspace:
            if composing.isEmpty {
                controller.backspace()
                candidates = []
                // 删掉已上屏的字：造词链作废（删过的字不该再拼进新词）
                InputEngine.shared.resetChain()
            } else {
                composing.removeLast()
                refresh()
            }

        case .space:
            if composing.isEmpty {
                // 连点两下空格 = 句号（对标百度/系统键盘）
                let now = Date()
                if now.timeIntervalSince(lastSpaceTap) < 0.4 {
                    lastSpaceTap = .distantPast
                    controller.backspace()
                    controller.insert("。")
                    autoCap(after: "。")
                    InputEngine.shared.clearContext()
                } else {
                    lastSpaceTap = now
                    controller.insert(" ")
                    // 空格是词边界：造词链作废（「我 世界」不该学成「我世界」），
                    // 但上下文学习保留（空格后的候选仍可跟着前文排）
                    InputEngine.shared.resetChain()
                }
                candidates = []
            } else {
                commitComposing()
            }

        case .ret:
            commitComposing()
            controller.newline()
            candidates = []
            autoCap(after: "\n")
            InputEngine.shared.clearContext()

        case .globe:
            commitComposing()
            controller.advanceToNextInputMode()

        case .toLayer(let l):
            commitComposing()
            layer = l
            shiftOn = false
        }
    }

    /// 上屏联想：把本地 bigram 命中的后继词摆进候选栏。
    /// 没有命中就安静收起，不留一块空白栏。
    private func showAssociates(for word: String) {
        let list = InputEngine.shared.associate(word)
        guard !list.isEmpty else {
            assocMode = false
            candidates = []
            return
        }
        assocMode = true
        candidates = list.map {
            PinyinCandidate(word: $0, score: 0, consumed: 0, literal: false)
        }
    }

    private func clearAssociates() {
        guard assocMode else { return }
        assocMode = false
        candidates = []
    }

    /// 长按候选：把它从用户词频里抹掉，下次不再冒头
    private func forget(_ word: String) {
        PinyinEngine.shared.forget(word)
        if composing.isEmpty {
            candidates = []
        } else {
            refresh()
        }
    }

    /// 长按候选：在该拼音下置顶 / 取消置顶（对标百度 PlumCore ipt_set_firstword）。
    /// 置顶后立刻重排，用户能看到它跳到第一格 —— 这就是操作反馈。
    private func pin(_ word: String) {
        let py = enginePy.isEmpty ? composing : enginePy
        guard !py.isEmpty else { return }
        InputEngine.shared.togglePin(word: word, pinyin: py)
        if !composing.isEmpty { refresh() }
    }

    /// 字母键上滑（q~o = 1~9）：选候选拦对应位置的候选。
    /// 没打字、候选拦是空的，上滑就没效果 —— 上滑只做选候选 不打数字。
    private func swipe(_ spec: KeySpec, _ ch: String) {
        guard let n = Int(ch), n >= 1 else { return }
        let list = panel == .thought ? thoughtCands : candidates
        guard n <= list.count else { return }
        let c = list[n - 1]
        if panel == .thought { pickThought(c) } else { pick(c) }
    }

    /// 退格上滑：正在拼 → 清掉整串拼音（重打）。
    /// 没在拼 → 回退：把最近一次上屏的内容直接从文本框删掉（不还原拼音），
    /// 思想库模式下连面板输入框一起清。逐字上屏进行中不回退（跟发送打架）。
    private func clearComposing() {
        if !composing.isEmpty {
            composing = ""
            enginePy = ""
            candidates = []
            controller.setComposing("")
            return
        }
        if thoughtBusy { return }
        let last = lastOutput
        lastOutput = nil
        if let last, !last.text.isEmpty {
            for _ in 0..<last.text.count { controller.backspace() }
            if !last.thought { InputEngine.shared.forget(last.text) }
        }
        if panel == .thought { clearThoughtInput() }
    }

    private func tapShift() {
        let now = Date()
        let doubleTap = now.timeIntervalSince(lastShiftTap) < 0.35
        lastShiftTap = now
        if doubleTap {
            capsLock.toggle()
            shiftOn = false
        } else if capsLock {
            capsLock = false
            shiftOn = false
        } else {
            shiftOn.toggle()
        }
    }

    /// 句末标点后不再自动点亮大写 —— 中文键盘自动大写没意义，
    /// 反而会在标点后把下一个字母当英文直接上屏（「打字出字母」的另一来源）。
    /// 需要英文大写一律手动按 ⇧。
    private func autoCap(after t: String) {
        _ = t
        if shiftOn && !capsLock { shiftOn = false }
    }

    // MARK: - 输入态同步

    /// 拼音串变了：重算候选
    private func refresh() {
        assocMode = false
        // 拼音行显隐 → 键盘整体高度要跟着变（多一行拼音行）
        controller.setComposingRow(!composing.isEmpty)
        if composing.isEmpty {
            enginePy = ""
            controller.setComposing("")
            return
        }
        enginePy = composing
        candidates = enginePy.isEmpty ? [] : InputEngine.shared.candidates(for: enginePy)
        controller.setComposing(composing)
    }

    /// 把当前拼音串按首选候选上屏。
    /// 只上屏真正的汉字候选 —— 找不到汉字时宁可什么都不做，也绝不把裸拼音当字母吐出去。
    /// （「打字打出英文字母」的根因就是这里兜底上了 composing 本身。）
    private func commitComposing() {
        guard !composing.isEmpty else { return }
        if candidates.isEmpty { refresh() }
        guard let best = candidates.first(where: { !$0.literal }) else { return }
        applyCommit(best, pinyin: enginePy.isEmpty ? composing : enginePy)
    }

    /// 点了候选栏里的词（含联想）
    private func pick(_ c: PinyinCandidate) {
        if assocMode {
            // 联想词直接上屏，并顺着新词继续联想（可以一路点下去）
            controller.commit(c.word)
            lastOutput = (c.word, false)
            showAssociates(for: c.word)
            return
        }
        applyCommit(c, pinyin: enginePy.isEmpty ? composing : enginePy)
    }

    /// 上屏一个词。若这条候选只吃掉了拼音串的一部分（比如打 jintianx 选了「今天」），
    /// 剩下的「x」继续留在串里接着拼 —— 百度就是这么干的。
    private func applyCommit(_ c: PinyinCandidate, pinyin: String) {
        controller.commit(c.word)
        let used = InputEngine.shared.commit(c, pinyin: pinyin)
        lastOutput = (c.word, false)

        let restPy = used < pinyin.count ? String(pinyin.dropFirst(used)) : ""
        composing = restPy
        controller.setComposingRow(!composing.isEmpty)
        if composing.isEmpty {
            // 商业级上屏联想：按刚打的词给后继词（本地 bigram，不联网）
            showAssociates(for: c.word)
        } else {
            enginePy = composing
            controller.setComposing(composing)
            candidates = enginePy.isEmpty ? [] : InputEngine.shared.candidates(for: enginePy)
        }
    }

    private func check() {
        loadThoughtProgress()
        pullSettings()
        refreshReturnLabel()
        // librime 后台部署（首次要把预编译词库落到沙盒），不阻塞首帧；
        // 没就绪前候选走自研引擎，就绪后自动切过去。
        RimeService.shared.prepare()
        // 思想库面板没被主动关过就还原
        if panel == .none,
           UserDefaults.standard.bool(forKey: "anran_thought_panel_on") {
            setPanel(.thought)
        }
    }

    /// 主程序下发的配置：只读本机落盘的那份，不联网
    private func refreshLocalStores() {
        KBMetrics.cfg = KBConfigStore.current
        PinyinEngine.shared.setPhrases(PhraseStore.current.items)
        // 只认「使用中」的那本思想库 没选库 = 全部库都参与
        // （设置页左滑点「使用」选中的库 其他库的关键词一概不调）
        thoughts = ThoughtStore.current.activeItems
        brushTexts = BrushStore.current.items
        applyLearnResetIfNeeded()
    }

    private func pullSettings() {
        refreshLocalStores()
        // 本地链路：主 app 秒推的那份走回环 TCP（几十毫秒），全程不联网。
        pullLocalIfNew()
    }

    /// 秒同步落盘 + 界面刷新：本地拉回的整包比上次新才动。
    /// 与服务器拉取共用 appliedKey 去重（ConfigSync.pullLocal 内部），
    /// 两条路谁先到都不会把同一份包落两遍。
    private func pullLocalIfNew() {
        ConfigSync.pullLocal { changed in
            guard changed else { return }
            refreshLocalStores()
            controller.setRows(KBMetrics.rows)
            cfgRev += 1
            if !composing.isEmpty { refresh() }
        }
    }

    /// 主程序点了「清空打字学习记录」：见到比本地新的令牌就清一次
    private func applyLearnResetIfNeeded() {
        let token = IMESettingsStore.current.clearLearnToken
        let key = "anran_learn_reset_done"
        let done = UserDefaults.standard.integer(forKey: key)
        guard token > done else { return }
        PinyinEngine.shared.clearLearning()
        UserDefaults.standard.set(token, forKey: key)
    }
}
