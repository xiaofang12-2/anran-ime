import SwiftUI
import UIKit

/// 键盘界面
///
/// 先过授权门：没登录（或票据过期）就只显示一块「未授权」面板，
/// 授权通过才放出真正的键盘。这样账号被禁用/解绑后键盘立刻失效。
struct KeyboardRootView: View {

    let controller: KeyboardViewController

    @State private var authorized = AuthStore.isLoggedIn
    @State private var hint = ""

    // 输入状态
    @State private var composing = ""                    // 拼音串（双拼模式下是双拼键串）
    @State private var enginePy = ""                     // 喂给引擎的全拼（双拼模式下是解码结果）
    @State private var candidates: [PinyinCandidate] = []
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
    /// 引擎诊断串（方案 id + 真实候选条数）。没有 App Groups，键盘沙箱里
    /// 的东西主程序读不到，候选栏空闲时露这一串是确认 librime 干没干活的唯一途径。
    @State private var engineDiag = ""

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

    // 登录墙：6位配对码输入（主程序「同步数据」出的码 在这里领登录态）
    @State private var pairCode = ""
    @State private var pairing = false
    /// 登录墙已把键盘撑高过（配对码小键盘比普通键盘高一截）
    @State private var gateExpanded = false

    /// 登录墙需要放下配对码键盘：撑高；授权通过后收回去
    private func updateGateExtra() {
        if !authorized {
            gateExpanded = true
            controller.setExtraHeight(210)
        } else if gateExpanded {
            gateExpanded = false
            panel = .none
            controller.setExtraHeight(0)
        }
    }

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
        Group {
            if authorized { keyboard } else { gate }
        }
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
        // 后台把账号禁用/解绑后，心跳回调广播踢人 —— 立刻收掉键盘切回登录墙
        .onReceive(NotificationCenter.default.publisher(for: .anranAuthKicked)) { _ in
            authorized = false
            composing = ""
            enginePy = ""
            candidates = []
            panel = .none
            // 面板是被系统踢下去的不是用户主动关的：记忆保留 只收面板
            UserDefaults.standard.set(false, forKey: "anran_thought_panel_on")
            updateGateExtra()
        }
        // librime 后台部署跑完（成功或失败）都会广播，这时候诊断串才有意义：
        // 部署在后台线程，首帧读到的必然还是「未就绪」，不补这一下永远看不到结果。
        .onReceive(NotificationCenter.default.publisher(for: .anranRimeReady)) { _ in
            engineDiag = Self.diag
        }
    }

    /// 诊断串 = 引擎状态 + 内存足迹。内存那截是闪退排查的抓手：
    /// 键盘扩展被 jetsam 杀掉不留现场，只有这条串能看出是不是顶着红线跑。
    private static var diag: String {
        var s = RimeService.shared.diagnostics + " " + CrashReporter.memoryDiag()
        // 自研引擎上一次全量解码耗时：性能调度调优的唯一抓手
        // （ms 数只在 librime 没起来/候选稀薄走全量路径时才有意义）
        s += String(format: " dec%.1fms", PinyinEngine.shared.lastDecodeMs)
        if !CrashReporter.lastCrash().isEmpty { s += " CRASH" }
        return s
    }

    // MARK: - 已授权：正常键盘

    private var keyboard: some View {
        VStack(spacing: KBMetrics.rowGap) {
            topBar
            panels
            expandedGrid
            keyRows
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
        let badge = (panel != .thought && dpScheme != .off) ? dpScheme.displayName : ""
        return TopBar(thoughtOn: panel == .thought,
               clipboardOn: panel == .clipboard,
               typing: typing,
               composing: panel == .thought ? (thoughtQuery + thoughtComposing) : composing,
               candidates: panel == .thought ? thoughtCands : candidates,
               onPick: panel == .thought ? pickThought : pick,
               onForget: panel == .thought ? { _ in } : forget,
               expandOn: expandedCandidates,
               schemeBadge: badge,
               onToggleExpand: toggleExpandCandidates,
               onClipboard: toggleClipboard,
               onThought: toggleThought,
               onThoughtLongPress: { controller.openHost("thoughts") },
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
    private var keyRows: some View {
        ForEach(rows.indices, id: \.self) { i in
            KeyRow(keys: rows[i],
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
            : !composing.isEmpty
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
        let py = engineInput(thoughtComposing)
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
    /// 智能分行：按 Unicode 标准换行拆（\n / \r\n / \r / U+2028/U+2029 全认），
    /// 不管从微信、网页还是备忘录粘进来的多行内容，一句是一句，绝不叠成一行。
    private func thoughtContentLines(_ content: String) -> [String] {
        var lines: [String] = []
        content.enumerateLines { line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(t) }
        }
        return lines
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

    /// 长按候选：把它从用户词频里抹掉，下次不再冒头
    private func forget(_ word: String) {
        PinyinEngine.shared.forget(word)
        if composing.isEmpty {
            candidates = []
        } else {
            refresh()
        }
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

    /// 当前双拼方案（设置改了即时生效，不用重开键盘）
    private var dpScheme: DoublePinyinScheme {
        DoublePinyinScheme.safe(IMESettingsStore.current.doublePinyin)
    }

    /// 双拼模式下把键串解码成全拼喂给引擎；解不了就透传原键
    /// （不成对的尾键 / 简拼 / 英文，走原有路径）。
    /// 单键在双拼里不成音节，直接不出候选（商业双拼输入器的行为）。
    private func engineInput(_ keys: String) -> String {
        let scheme = dpScheme
        guard scheme != .off else { return keys }
        if keys.count == 1 { return "" }
        if let d = DoublePinyin.decodePrefix(keys, scheme: scheme) { return d.full }
        return keys
    }

    /// 拼音串变了：重算候选
    private func refresh() {
        if composing.isEmpty {
            enginePy = ""
            controller.setComposing("")
            return
        }
        enginePy = engineInput(composing)
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
        applyCommit(c, pinyin: enginePy.isEmpty ? composing : enginePy)
    }

    /// 上屏一个词。若这条候选只吃掉了拼音串的一部分（比如打 jintianx 选了「今天」），
    /// 剩下的「x」继续留在串里接着拼 —— 百度就是这么干的。
    /// 双拼模式下剩下的全拼要编回双拼键串，未成对的尾键原样保留。
    private func applyCommit(_ c: PinyinCandidate, pinyin: String) {
        controller.commit(c.word)
        let used = InputEngine.shared.commit(c, pinyin: pinyin)
        lastOutput = (c.word, false)

        let restPy = used < pinyin.count ? String(pinyin.dropFirst(used)) : ""
        let pending = (dpScheme != .off && composing.count % 2 == 1)
            ? String(composing.last!) : ""
        if restPy.isEmpty {
            composing = pending
        } else if dpScheme != .off,
                  let enc = DoublePinyin.encode(restPy, scheme: dpScheme) {
            composing = enc + pending
        } else {
            // 编码失败（极端情况）：按全拼残留接着拼，功能不碎
            composing = restPy + pending
        }
        if composing.isEmpty {
            // 上屏完就完 不做联想：候选拦只跟着拼音串走
            candidates = []
        } else {
            enginePy = engineInput(composing)
            controller.setComposing(composing)
            candidates = enginePy.isEmpty ? [] : InputEngine.shared.candidates(for: enginePy)
        }
    }

    // MARK: - 未授权：授权门（配对码连接器）

    private var gate: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text("未授权")
                .font(.system(size: 16, weight: .semibold))
            Text(hint.isEmpty
                 ? "主程序登录后点「同步数据」出一个6位配对码\n（重装 / 换机后点「重新配对键盘」）\n在下面输入配对码  一次配对 永久自动同步\n系统设置需给本键盘开「允许完全访问」"
                 : hint)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 配对码格子
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Text(i < pairCode.count ? String(pairCode[pairCode.index(pairCode.startIndex, offsetBy: i)]) : "")
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(KBMetrics.themeCandidateTextColor)
                        .frame(width: 34, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(KBMetrics.themeKeyColor.opacity(0.92)))
                }
            }
            .padding(.top, 2)

            // 数字小键盘：1-9 / 删除 0 配对
            VStack(spacing: 8) {
                ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { n in
                            padButton(String(n)) { pairCode += String(n) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    padButton("删除") {
                        if !pairCode.isEmpty { pairCode.removeLast() }
                    }
                    padButton("0") { pairCode += "0" }
                    padButton(pairing ? "配对中" : "配对") { doPairClaim() }
                        .opacity((pairCode.count == 6 && !pairing) ? 1 : 0.55)
                }
            }

            GateButton(label: "打开主程序") { controller.openHostApp() }
            if !hint.isEmpty {
                GateButton(label: "重试") { check() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func padButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            KeySound.play()
            action()
        } label: {
            Text(label)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundColor(KBMetrics.themeCandidateTextColor)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(KBMetrics.themeKeyColor.opacity(0.92))
                        .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 1))
        }
        .buttonStyle(.plain)
    }

    /// 配对码换登录态，成了立刻拉一次整包配置
    private func doPairClaim() {
        guard pairCode.count == 6, !pairing else { return }
        pairing = true
        AnRanAPI.shared.pairClaim(code: pairCode) { res in
            pairing = false
            if res.ok, !res.ticket.isEmpty {
                AuthStore.write(AuthState(username: res.username,
                                          ticket: res.ticket,
                                          machine: res.machine,
                                          expireAt: res.expireAt,
                                          savedAt: Int(Date().timeIntervalSince1970),
                                          logoutSeq: res.logoutSeq))
                pairCode = ""
                hint = ""
                check()
            } else if res.error == "bad_or_expired" {
                hint = "配对码不对或已过期  主程序重新点「同步数据」拿新码"
            } else {
                hint = "配对失败（\(res.error.isEmpty ? "网络不通" : res.error)）"
            }
        }
    }

    private func check() {
        // 先把本地已落盘的配置刷一遍，再异步从服务器拉新包（配对/主程序推送的）
        loadThoughtProgress()
        pullSettings()
        refreshReturnLabel()
        authorized = AuthStore.isLoggedIn
        updateGateExtra()
        if authorized {
            hint = ""
            // librime 后台部署（首次要把预编译词库落到沙盒），不阻塞首帧；
            // 没就绪前候选走自研引擎，就绪后自动切过去。
            RimeService.shared.prepare()
            engineDiag = Self.diag
            controller.refreshAuth()
            // 思想库面板没被主动关过就还原（键盘收起再弹出 / 扩展进程被杀重开）：
            // 面板和关键词进度都接回去 接着上次那句走 只有主动关了才从头开始
            if panel == .none,
               UserDefaults.standard.bool(forKey: "anran_thought_panel_on") {
                setPanel(.thought)
            }
        } else {
            composing = ""
            enginePy = ""
            candidates = []
        }
    }

    /// 主程序下发的配置：本地已落盘的先刷上，服务器有新包拉到再刷一遍
    private func refreshLocalStores() {
        KBMetrics.cfg = KBConfigStore.current
        PinyinEngine.shared.setPhrases(PhraseStore.current.items)
        // 只认「使用中」的那本思想库 没选库 = 全部库都参与
        // （设置页左滑点「使用」选中的库 其他库的关键词一概不调）
        thoughts = ThoughtStore.current.activeItems
        applyLearnResetIfNeeded()
    }

    private func pullSettings() {
        refreshLocalStores()
        // 本地链路先拉：主 app 秒推的那份走回环 TCP（几十毫秒），比服务器
        // 拉取快几个数量级。真落盘了下面的服务器拉取会因 appliedKey 去重
        // 自动跳过，不会重复刷一遍；主 app 没在跑则 1.5 秒超时后走服务器。
        pullLocalIfNew()
        ConfigSync.pullFromServer { changed in
            guard changed else { return }
            refreshLocalStores()
            controller.setRows(KBMetrics.rows)
            cfgRev += 1
            if !composing.isEmpty { refresh() }
        }
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

private struct GateButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.black)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.2),
                                radius: 0, x: 0, y: 1))
        }
        .buttonStyle(.plain)
    }
}
