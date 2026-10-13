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
    @State private var composing = ""                    // 拼音串
    @State private var candidates: [PinyinCandidate] = []
    @State private var layer: KBLayer = .letters
    @State private var shiftOn = false
    @State private var capsLock = false
    @State private var lastShiftTap = Date.distantPast
    @State private var lastSpaceTap = Date.distantPast
    /// 配置/短语从主程序接过来后 +1，逼界面按新尺寸重画
    @State private var cfgRev = 0
    /// 回车键文案：跟宿主 App 的 returnKeyType 走（聊天软件显示「发送」）
    @State private var returnLabel = "换行"
    /// 上一次从剪贴板重拉配置的时间（起词时节流重拉用）
    @State private var lastSyncAt = Date.distantPast

    // 顶部功能栏 / 浮层面板
    @State private var panel: KBPanel = .none
    @State private var thoughtQuery = ""
    @State private var thoughtComposing = ""                 // 面板里的拼音串
    @State private var thoughtCands: [PinyinCandidate] = []
    @State private var thoughtLine = 0                       // 命中内容输出到第几行
    @State private var clipboardText = ""
    @State private var thoughts: [ThoughtItem] = []

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
    }

    // MARK: - 已授权：正常键盘

    private var keyboard: some View {
        VStack(spacing: KBMetrics.rowGap) {
            FunctionBar(thoughtOn: panel == .thought,
                        clipboardOn: panel == .clipboard,
                        onClipboard: toggleClipboard,
                        onPhrase: { controller.openHost("phrases") },
                        onThought: toggleThought,
                        onThoughtLongPress: { controller.openHost("thoughts") },
                        onCollapse: { controller.dismissKeyboardNow() })

            if panel == .clipboard {
                ClipboardPanel(text: clipboardText,
                               onInsert: insertClipboard,
                               onClose: closePanel)
            }
            if panel == .thought {
                ThoughtPanel(query: thoughtQuery,
                             composing: thoughtComposing,
                             matches: thoughtMatches,
                             onInsert: insertThought,
                             onClose: closePanel)
            }

            if panel == .thought {
                // 面板里的拼音候选走同一根候选栏（键盘扩展弹不出系统键盘，
                // 面板的输入只能由键盘自己的键喂进来，候选也在这儿选）
                CandidateBar(composing: thoughtComposing,
                             candidates: thoughtCands,
                             onPick: pickThought,
                             onForget: { _ in })
            } else {
                CandidateBar(composing: composing,
                             candidates: candidates,
                             onPick: pick,
                             onForget: forget)
            }
            ForEach(rows.indices, id: \.self) { i in
                KeyRow(keys: rows[i],
                       onKey: handle,
                       onSwipe: swipe,
                       onDeleteClear: clearComposing,
                       onSpaceMove: { controller.moveCursor($0) },
                       onLongPress: longPress)
            }
        }
    }

    // MARK: - 功能栏 / 面板

    /// 面板开合：把多出来的高度报给键盘容器，否则展开的行会被裁掉
    private func setPanel(_ p: KBPanel) {
        panel = p
        let extra: CGFloat
        switch p {
        case .none: extra = 0
        case .clipboard: extra = KBMetrics.panelHeight + KBMetrics.rowGap
        // 思想库面板：输入框面板 + 一根候选栏（面板里打拼音要在候选栏选汉字）
        case .thought: extra = KBMetrics.thoughtPanelHeight
            + KBMetrics.barHeight + KBMetrics.rowGap * 2
        }
        controller.setExtraHeight(extra)
    }

    private func toggleClipboard() {
        if panel == .clipboard {
            setPanel(.none)
        } else {
            clipboardText = Self.visibleClipboard()
            setPanel(.clipboard)
        }
    }

    /// 剪贴板面板只显示用户自己复制的东西。
    /// 主程序把配置（布局/短语/设置/思想库/登录态）打包塞进剪贴板交接，
    /// 那段 ANRAN-* 文本不是给用户看的，露出来只会让人一脸懵。
    private static func visibleClipboard() -> String {
        let raw = UIPasteboard.general.string ?? ""
        if raw.hasPrefix(SyncBundle.prefix) || raw.hasPrefix("ANRAN-") { return "" }
        return raw
    }

    private func toggleThought() {
        if panel == .thought {
            setPanel(.none)
        } else {
            // 点图标算用户手势，这时候读一次主程序下发的最新配置（思想库/短语），
            // 免得刚在设置里加完关键词、切回键盘还调不出内容。
            pullSettings()
            thoughtQuery = ""
            thoughtComposing = ""
            thoughtCands = []
            thoughtLine = 0
            setPanel(.thought)
        }
    }

    private func closePanel() {
        setPanel(.none)
    }

    /// 思想库命中：关键词或内容里带任意一个查询串。
    ///
    /// 查询串见 `thoughtQueries`：已落定的关键词框内容、正在拼的裸串、
    /// 候选栏里的汉字。三样一起上才不漏 —— 字母关键词（mw）没有汉字可落，
    /// 只能靠裸串；拼音关键词（kouzi → 扣字1）靠候选栏里的汉字。
    private var thoughtMatches: [ThoughtItem] {
        let qs = thoughtQueries
        guard !qs.isEmpty else { return Array(thoughts.prefix(12)) }
        // 分档：关键词完全相等 > 关键词前缀 > 关键词/内容包含。
        // 分档是为了让「打全了关键词」的那条永远排在「只是内容里撞见」的前面。
        var exact: [ThoughtItem] = []
        var prefix: [ThoughtItem] = []
        var partial: [ThoughtItem] = []
        for it in thoughts {
            let k = it.cleanKeyword
            let c = it.content.lowercased()
            var tier = 0
            for q in qs {
                if k == q { tier = max(tier, 3) }
                else if k.hasPrefix(q) { tier = max(tier, 2) }
                else if q.count >= 2 && (k.contains(q) || c.contains(q)) { tier = max(tier, 1) }
            }
            switch tier {
            case 3: exact.append(it)
            case 2: prefix.append(it)
            case 1: partial.append(it)
            default: break
            }
        }
        return Array((exact + prefix + partial).prefix(12))
    }

    /// 思想库检索用的查询串集合（关键词框内容 + 裸拼音串 + 候选栏里的汉字）。
    ///
    /// 候选栏里的汉字要**整条都拿去比**，不能只认第一个：打 kouzi 时首选可能是
    /// 「口子」，而用户建的关键词是「扣字1」—— 只认首选就永远匹配不上，
    /// 用户就会觉得「关键词调不出内容」。整条候选栏过一遍才稳。
    private var thoughtQueries: [String] {
        var qs: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !t.isEmpty && !qs.contains(t) { qs.append(t) }
        }
        add(thoughtQuery)
        if !thoughtComposing.isEmpty {
            add(thoughtComposing)
            for c in thoughtCands where !c.literal { add(c.word) }
        }
        return qs
    }

    private func insertClipboard(_ text: String) {
        controller.commit(text)
        closePanel()
    }

    private func insertThought(_ content: String) {
        controller.commit(content)
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
            thoughtLine = 0
        case .backspace:
            if !thoughtComposing.isEmpty {
                thoughtComposing.removeLast()
                refreshThoughtCands()
            } else if !thoughtQuery.isEmpty {
                thoughtQuery.removeLast()
                thoughtLine = 0
            }
        case .space:
            if !thoughtComposing.isEmpty {
                commitThoughtComposing()
            } else {
                thoughtQuery += " "
                thoughtLine = 0
            }
        case .ret:
            // 回车 = 出内容：命中就用当前查询串（含正在拼的裸串/首选字）输出一行。
            // 不强制先落定候选 —— 打 mw 这种字母关键词本来就没有汉字可落，
            // 硬落反而把 mw 顶掉，用户会觉得「回车没用」。
            outputThoughtLine()
        case .globe:
            controller.advanceToNextInputMode()
        case .toLayer(let l):
            layer = l
        default:
            break
        }
    }

    private func refreshThoughtCands() {
        thoughtCands = thoughtComposing.isEmpty
            ? []
            : InputEngine.shared.candidates(for: thoughtComposing)
    }

    /// 候选栏里点汉字：落进思想库输入框
    private func pickThought(_ c: PinyinCandidate) {
        guard !c.literal else { return }
        thoughtQuery += c.word
        thoughtComposing = ""
        thoughtCands = []
        thoughtLine = 0
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

    /// 回车：第二输入框里打的东西直接往第一输入框送，并顺手发出去。
    /// - 打的是关键词（或关键词的一部分）→ 送出关键词内容，按句走：
    ///   第一次回车送第一句，再按一次送第二句，一轮走完从头再来；
    ///   关键词本身永远不出去。
    /// - 没命中任何关键词 → 把第二输入框里打的原文原样送出去。
    /// 两种情况送完都补一个回车，让宿主输入框直接发送。
    /// 什么都没打时（刚开面板）回车不输出，避免莫名其妙吐一句。
    private func outputThoughtLine() {
        guard !thoughtQueries.isEmpty else { return }

        if let hit = thoughtMatches.first {
            let lines = hit.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return }
            // 一轮输出完再从头来，方便反复调用同一段内容
            if thoughtLine >= lines.count { thoughtLine = 0 }
            controller.commitAndSend(lines[thoughtLine])
            thoughtLine += 1
        } else {
            let text = thoughtPlainText
            guard !text.isEmpty else { return }
            controller.commitAndSend(text)
        }
    }

    /// 第二输入框里当前打的原文：已落定的内容 + 还没落定的拼音串
    /// （有汉字首选就落首选，没有就留裸串，打 mw 这种字母关键词也不丢）
    private var thoughtPlainText: String {
        var s = thoughtQuery
        if !thoughtComposing.isEmpty {
            if let best = thoughtCands.first(where: { !$0.literal }) {
                s += best.word
            } else {
                s += thoughtComposing
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rows: [[KeySpec]] {
        let base = KeyboardLayout.rows(layer: layer,
                                       shift: shiftOn || capsLock,
                                       swipe: IMESettingsStore.current.swipeNumber)
        let applied = KeyOverrideApplier.apply(base, overrides: KBMetrics.cfg.keyOverrides)
        guard returnLabel != "换行" else { return applied }
        // 回车键文案换成宿主 App 要的那个（发送 / 搜索 / 前往…）
        return applied.map { row in
            row.map { spec in
                guard case .ret = spec.action else { return spec }
                return KeySpec(spec.id, returnLabel, spec.weight, spec.action,
                               special: spec.special, popup: spec.popup,
                               active: spec.active, swipe: spec.swipe,
                               symbol: spec.symbol)
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

        case .shift:
            tapShift()

        case .backspace:
            if composing.isEmpty {
                controller.backspace()
                candidates = []
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
                } else {
                    lastSpaceTap = now
                    controller.insert(" ")
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

    /// 字母键上滑：直接把副字符（数字）打出去
    private func swipe(_ spec: KeySpec, _ ch: String) {
        commitComposing()
        controller.insert(ch)
        candidates = []
    }

    /// 退格上滑：清掉整串拼音
    private func clearComposing() {
        if composing.isEmpty {
            candidates = []
        } else {
            composing = ""
            candidates = []
            controller.setComposing("")
        }
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
        if composing.isEmpty {
            controller.setComposing("")
            return
        }
        candidates = InputEngine.shared.candidates(for: composing)
        controller.setComposing(composing)
    }

    /// 把当前拼音串按首选候选上屏。
    /// 只上屏真正的汉字候选 —— 找不到汉字时宁可什么都不做，也绝不把裸拼音当字母吐出去。
    /// （「打字打出英文字母」的根因就是这里兜底上了 composing 本身。）
    private func commitComposing() {
        guard !composing.isEmpty else { return }
        if candidates.isEmpty { refresh() }
        guard let best = candidates.first(where: { !$0.literal }) else { return }
        applyCommit(best, pinyin: composing)
    }

    /// 点了候选栏里的词（含联想）
    private func pick(_ c: PinyinCandidate) {
        applyCommit(c, pinyin: composing)
    }

    /// 上屏一个词。若这条候选只吃掉了拼音串的一部分（比如打 jintianx 选了「今天」），
    /// 剩下的「x」继续留在串里接着拼 —— 百度就是这么干的。
    private func applyCommit(_ c: PinyinCandidate, pinyin: String) {
        controller.commit(c.word)
        let used = InputEngine.shared.commit(c, pinyin: pinyin)

        let rest = used < pinyin.count ? String(pinyin.dropFirst(used)) : ""
        composing = rest
        if rest.isEmpty {
            // 上屏后立刻联想下一个字
            candidates = InputEngine.shared.associate(c.word)
                .map { PinyinCandidate(word: $0, score: 0) }
        } else {
            controller.setComposing(rest)
            candidates = InputEngine.shared.candidates(for: rest)
        }
    }

    // MARK: - 未授权：授权门

    private var gate: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text("未授权")
                .font(.system(size: 16, weight: .semibold))
            Text(hint.isEmpty
                 ? "请先在「黯然输入法」里登录账号"
                 : hint)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                GateButton(label: "接取登录") {
                    // 整包（带登录态）先接；接不到再退旧式单票据
                    _ = ConfigSync.pull()
                    if !AuthStore.isLoggedIn { _ = AuthStore.importFromPasteboard() }
                    if AuthStore.isLoggedIn {
                        hint = ""
                        check()
                    } else {
                        hint = "没接到登录态，请先在主程序点「同步登录状态到键盘」"
                    }
                }
                GateButton(label: "打开主程序") { controller.openHostApp() }
                GateButton(label: "重试") { check() }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func check() {
        // 先接整包（配置 + 登录态一起落），再兜底接旧式单票据。
        // 整包里带登录态，所以这里落完 AuthStore 就能直接判登录了。
        pullSettings()
        refreshReturnLabel()
        if !AuthStore.isLoggedIn {
            _ = AuthStore.importFromPasteboard()
        }
        authorized = AuthStore.isLoggedIn
        if authorized {
            hint = ""
            // librime 后台部署（首次要把预编译词库落到沙盒），不阻塞首帧；
            // 没就绪前候选走自研引擎，就绪后自动切过去。
            RimeService.shared.prepare()
            controller.refreshAuth()
        } else {
            composing = ""
            candidates = []
        }
    }

    /// 从主程序接「键盘布局」「自定义短语」「输入设置」：剪贴板里有更新的整包就换，换完重画
    private func pullSettings() {
        let changed = ConfigSync.pull()

        KBMetrics.cfg = KBConfigStore.current
        PinyinEngine.shared.setPhrases(PhraseStore.current.items)
        thoughts = ThoughtStore.current.activeItems
        applyLearnResetIfNeeded()

        if changed {
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
