import SwiftUI

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

    var body: some View {
        Group {
            if authorized { keyboard } else { gate }
        }
        .padding(.horizontal, KBMetrics.sideInset)
        .padding(.top, KBMetrics.topInset)
        .padding(.bottom, KBMetrics.bottomInset)
        .background(Color(red: 0.82, green: 0.83, blue: 0.85))
        .onAppear {
            _ = cfgRev
            check()
        }
    }

    // MARK: - 已授权：正常键盘

    private var keyboard: some View {
        VStack(spacing: KBMetrics.rowGap) {
            CandidateBar(composing: composing,
                         candidates: candidates,
                         onPick: pick,
                         onForget: forget)
            ForEach(rows.indices, id: \.self) { i in
                KeyRow(keys: rows[i],
                       onKey: handle,
                       onSwipe: swipe,
                       onDeleteClear: clearComposing,
                       onSpaceMove: { controller.moveCursor($0) })
            }
        }
    }

    private var rows: [[KeySpec]] {
        KeyboardLayout.rows(layer: layer, shift: shiftOn || capsLock)
    }

    // MARK: - 按键分发

    private func handle(_ spec: KeySpec) {
        switch spec.action {
        case .letter(let c):
            if shiftOn || capsLock {
                commitComposing()
                controller.insert(c.uppercased())
                candidates = []
                if shiftOn && !capsLock { shiftOn = false }
            } else {
                composing += c
                refresh()
            }

        case .text(let t):
            commitComposing()
            controller.insert(t)
            candidates = []
            if layer != .letters { layer = .letters }
            shiftOn = false

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

    // MARK: - 输入态同步

    /// 拼音串变了：重算候选
    private func refresh() {
        if composing.isEmpty {
            controller.setComposing("")
            return
        }
        candidates = PinyinEngine.shared.candidates(for: composing)
        controller.setComposing(composing)
    }

    /// 把当前拼音串按首选候选上屏
    private func commitComposing() {
        guard !composing.isEmpty else { return }
        let best = candidates.first(where: { !$0.literal }) ?? candidates.first
        let word = best?.word ?? composing
        applyCommit(word, pinyin: composing, consumed: best?.consumed ?? composing.count)
    }

    /// 点了候选栏里的词（含联想）
    private func pick(_ c: PinyinCandidate) {
        applyCommit(c.word, pinyin: composing, consumed: c.consumed)
    }

    /// 上屏一个词。若这条候选只吃掉了拼音串的一部分（比如打 jintianx 选了「今天」），
    /// 剩下的「x」继续留在串里接着拼 —— 百度就是这么干的。
    private func applyCommit(_ word: String, pinyin: String, consumed: Int) {
        controller.commit(word)
        let used = (consumed > 0 && consumed <= pinyin.count) ? consumed : pinyin.count
        PinyinEngine.shared.learn(word, pinyin: String(pinyin.prefix(used)))

        let rest = used < pinyin.count ? String(pinyin.dropFirst(used)) : ""
        composing = rest
        if rest.isEmpty {
            // 上屏后立刻联想下一个字
            candidates = PinyinEngine.shared.associate(word)
                .map { PinyinCandidate(word: $0, score: 0) }
        } else {
            controller.setComposing(rest)
            candidates = PinyinEngine.shared.candidates(for: rest)
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
                    if AuthStore.importFromPasteboard(), AuthStore.isLoggedIn {
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
        // 共享容器拿不到时，剪贴板里可能有主程序放过来的票据，先接一次
        if !AuthStore.isLoggedIn {
            _ = AuthStore.importFromPasteboard()
        }
        pullSettings()
        authorized = AuthStore.isLoggedIn
        if authorized {
            hint = ""
            controller.refreshAuth()
        } else {
            composing = ""
            candidates = []
        }
    }

    /// 从主程序接「键盘布局」与「自定义短语」：剪贴板里有更新的就换，换完重画
    private func pullSettings() {
        let layoutChanged = KBConfigStore.pullFromPasteboard()
        let phrasesChanged = PhraseStore.pullFromPasteboard()

        KBMetrics.cfg = KBConfigStore.current
        PinyinEngine.shared.setPhrases(PhraseStore.current.items)

        if layoutChanged {
            controller.setRows(KBMetrics.rows)
        }
        if layoutChanged || phrasesChanged {
            cfgRev += 1
            if !composing.isEmpty { refresh() }
        }
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
