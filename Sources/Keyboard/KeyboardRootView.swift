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
    @State private var mode: KBMode = KeyboardRootView.savedMode

    var body: some View {
        Group {
            if authorized { keyboard } else { gate }
        }
        .padding(.horizontal, KBMetrics.sideInset)
        .padding(.top, KBMetrics.topInset)
        .padding(.bottom, KBMetrics.bottomInset)
        .background(Color(red: 0.82, green: 0.83, blue: 0.85))
        .onAppear(perform: check)
        .onChange(of: mode) { m in
            controller.setRows(KeyboardLayout.rowCount(mode: m))
        }
    }

    // MARK: - 已授权：正常键盘

    private var keyboard: some View {
        VStack(spacing: KBMetrics.rowGap) {
            CandidateBar(composing: composing, candidates: candidates, onPick: pick)
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
        KeyboardLayout.rows(layer: layer,
                            shift: shiftOn || capsLock,
                            mode: mode)
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

        case .t9(let d):
            composing += d
            refresh()

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
                controller.insert(" ")
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

        case .modeToggle:
            commitComposing()
            mode = (mode == .qwerty ? .t9 : .qwerty)
            Self.savedMode = mode
            composing = ""
            candidates = []
            layer = .letters
            shiftOn = false
        }
    }

    /// 字母键上滑：直接把副字符（数字）打出去
    private func swipe(_ spec: KeySpec, _ ch: String) {
        commitComposing()
        controller.insert(ch)
        candidates = []
    }

    /// 退格上滑：清掉整串拼音（或清掉联想）
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

    /// 拼音串变了：重算候选 + 更新输入框里的占位文本
    private func refresh() {
        if composing.isEmpty {
            controller.setComposing("")
            return
        }
        candidates = PinyinEngine.shared.candidates(for: composing, mode: mode)
        controller.setComposing(composing)
    }

    /// 把当前拼音串按首选候选上屏
    private func commitComposing() {
        guard !composing.isEmpty else { return }
        let word = candidates.first(where: { !$0.literal })?.word
            ?? candidates.first?.word
            ?? composing
        applyCommit(word)
    }

    /// 点了候选栏里的词（含联想）
    private func pick(_ word: String) {
        applyCommit(word)
    }

    private func applyCommit(_ word: String) {
        controller.commit(word)
        PinyinEngine.shared.learn(word)
        composing = ""
        // 上屏后立刻联想下一个字
        candidates = PinyinEngine.shared.associate(word)
            .map { PinyinCandidate(word: $0, score: 0) }
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
        authorized = AuthStore.isLoggedIn
        controller.setRows(KeyboardLayout.rowCount(mode: mode))
        if authorized {
            hint = ""
            controller.refreshAuth()
        } else {
            composing = ""
            candidates = []
        }
    }

    // MARK: - 形态偏好

    private static var savedMode: KBMode {
        get {
            KBMode(rawValue: UserDefaults.standard.string(forKey: "anran_kb_mode") ?? "qwerty")
                ?? .qwerty
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "anran_kb_mode")
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