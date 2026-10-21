import SwiftUI
import UIKit
import AudioToolbox

/// 按键音：加载键盘自带的「扣字」音效（click.wav）。
/// 开关与震动都读「输入设置」（IMESettingsStore），主程序里改了立刻生效。
/// 走 AudioServices 播系统音，不占音频会话，键盘扩展里最稳。
enum KeySound {
    private static var soundID: SystemSoundID = 0

    static func play() {
        guard IMESettingsStore.current.keySound else { return }
        if soundID == 0 {
            guard let url = Bundle.main.url(forResource: "click", withExtension: "wav") else {
                UIDevice.current.playInputClick()
                return
            }
            var sid: SystemSoundID = 0
            AudioServicesCreateSystemSoundID(url as CFURL, &sid)
            soundID = sid
        }
        AudioServicesPlaySystemSound(soundID)
    }

    /// 震动（默认关，用扣字音效替代）
    static func vibrate() {
        guard IMESettingsStore.current.vibration else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// 普通键帽：白底 + 底部 1px 投影，按下变灰缩放，上滑可打出副字符。
/// 长按只在传了 onLongPress 的键上生效（层切换键，用来切输入法）。
struct KeyCap: View {
    let spec: KeySpec
    let onTap: () -> Void
    var onSwipe: ((String) -> Void)? = nil
    var onLongPress: (() -> Void)? = nil

    @State private var pressed = false
    @State private var consumed = false
    @State private var longTimer: Timer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(fill(pressed))
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            capLabel
        }
        .scaleEffect(pressed && !spec.special ? 0.96 : 1)
        .overlay(alignment: .top) {
            if pressed && spec.popup { bubble }
        }
        .zIndex(pressed ? 20 : 0)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if consumed { return }
                    if !pressed {
                        pressed = true
                        KeySound.play()
                        KeySound.vibrate()
                        // 长按 0.5 秒才算长按（层切换键用它切输入法），抬手就取消
                        if onLongPress != nil {
                            longTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                                             repeats: false) { _ in
                                consumed = true
                                onLongPress?()
                            }
                        }
                    }
                    if let s = spec.swipe, v.translation.height < -28 {
                        consumed = true
                        pressed = false
                        cancelLong()
                        onSwipe?(s)
                    }
                }
                .onEnded { v in
                    cancelLong()
                    let was = pressed
                    pressed = false
                    if consumed { consumed = false; return }
                    if was && v.translation.height > -28 { onTap() }
                }
        )
        .onDisappear { cancelLong() }
    }

    /// 有图标画图标（shift / 退格），没图标画文字
    @ViewBuilder
    private var capLabel: some View {
        if let sym = spec.symbol {
            Image(systemName: sym)
                .font(.system(size: 19 * KBMetrics.fontScale, weight: .medium))
                .foregroundColor(KBMetrics.themeSpecialTextColor)
        } else {
            Text(spec.label)
                .font(.system(size: (spec.special ? 17 : 22) * KBMetrics.fontScale))
                .foregroundColor(KBMetrics.themeTextColor)
        }
    }

    private var bubble: some View {
        Text(spec.label)
            .font(.system(size: 28))
            .foregroundColor(KBMetrics.themeTextColor)
            .frame(width: 42, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(KBMetrics.themeKeyColor)
                    .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 2))
            .offset(y: -50)
            .allowsHitTesting(false)
    }

    private func cancelLong() {
        longTimer?.invalidate()
        longTimer = nil
    }

    private func fill(_ pressed: Bool) -> Color {
        if spec.active { return KBMetrics.themeAccentColor.opacity(0.15) }
        if spec.special {
            return pressed ? KBMetrics.themeSpecialPressedColor
                           : KBMetrics.themeSpecialColor
        }
        return pressed ? KBMetrics.themeKeyPressedColor : KBMetrics.themeKeyColor
    }
}

/// 退格键：对标百度手感 ——
///   单击只删一个字；按住 0.4 秒后才开始连删，先慢后快（0.13s → 0.08s → 0.045s）；
///   上滑清空整串拼音。
struct RepeatKey: View {
    let spec: KeySpec
    let onFire: () -> Void
    var onSwipeUp: (() -> Void)? = nil

    @State private var pressed = false
    @State private var consumed = false
    @State private var timer: Timer?
    @State private var repeats = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(pressed ? KBMetrics.themeKeyPressedColor
                              : KBMetrics.themeSpecialColor)
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            capLabel
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if consumed { return }
                    if v.translation.height < -40 {
                        consumed = true
                        stop()
                        onSwipeUp?()
                        return
                    }
                    if !pressed {
                        pressed = true
                        KeySound.play()
                        onFire()
                        repeats = 0
                        // 百度手感：先等 0.4 秒，确认是长按才开始连删
                        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                            scheduleRepeat()
                        }
                    }
                }
                .onEnded { _ in
                    consumed = false
                    stop()
                }
        )
        .onDisappear { stop() }
    }

    /// 有图标画图标（退格），没图标画文字
    @ViewBuilder
    private var capLabel: some View {
        if let sym = spec.symbol {
            Image(systemName: sym)
                .font(.system(size: 19 * KBMetrics.fontScale, weight: .medium))
                .foregroundColor(KBMetrics.themeSpecialTextColor)
        } else {
            Text(spec.label)
                .font(.system(size: 20))
                .foregroundColor(KBMetrics.themeSpecialTextColor)
        }
    }

    /// 连删节奏：先 0.13s 一个，删满 8 个提速到 0.08s，删满 20 个 0.045s 到底
    private func scheduleRepeat() {
        let interval: Double
        if repeats < 8 { interval = 0.13 }
        else if repeats < 20 { interval = 0.08 }
        else { interval = 0.045 }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            onFire()
            repeats += 1
            scheduleRepeat()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pressed = false
    }
}

/// 空格键：白底（对标参考图，空格是白的、只有功能键是灰的），
/// 点一下上屏/空格，左右滑动移动光标
struct SpaceKey: View {
    let spec: KeySpec
    let onTap: () -> Void
    let onMove: (Int) -> Void

    @State private var pressed = false
    @State private var consumed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(pressed ? KBMetrics.themeKeyPressedColor
                              : KBMetrics.themeKeyColor)
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            Text(spec.label)
                .font(.system(size: 15 * KBMetrics.fontScale))
                .foregroundColor(KBMetrics.themeTextColor)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if consumed { return }
                    if !pressed {
                        pressed = true
                        KeySound.play()
                    }
                    if abs(v.translation.width) > 24 {
                        consumed = true
                        let steps = Int(v.translation.width / 24)
                        if steps != 0 {
                            onMove(steps)
                        }
                    }
                }
                .onEnded { _ in
                    if consumed { consumed = false; pressed = false; return }
                    pressed = false
                    onTap()
                }
        )
    }
}

/// 一行键位：键宽按「10 键满行」的基准算死，少键的行整体居中。
/// 这样第二行会像 iOS 那样左右各缩进半个键，第三行 shift/退格 加宽后
/// 字母键也不会被挤窄（对标参考图）。
struct KeyRow: View {
    let keys: [KeySpec]
    let onKey: (KeySpec) -> Void
    let onSwipe: (KeySpec, String) -> Void
    let onDeleteClear: () -> Void
    let onSpaceMove: (Int) -> Void
    var onLongPress: (KeySpec) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let m = metrics(width: geo.size.width)
            HStack(spacing: KBMetrics.keyGap) {
                ForEach(keys) { spec in
                    keyView(spec)
                        .frame(width: m.unit * spec.weight)
                        // 单键高度覆盖（布局编辑器调的）：矮的键在行里垂直居中
                        .frame(height: spec.height ?? geo.size.height,
                               alignment: .center)
                }
            }
            .frame(width: m.rowWidth, height: geo.size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .frame(height: rowHeight)
    }

    /// 行高 = 行里最高的键（没单键覆盖就是标准键高）
    private var rowHeight: CGFloat {
        let custom = keys.compactMap { $0.height }.max() ?? 0
        return max(custom, KBMetrics.keyHeight)
    }

    /// 一行怎么摆：
    /// - 全等宽的行（字母行）—— 键宽固定成「10 键满行」的基准宽，整块居中。
    ///   这样第二行会像 iOS 那样左右各缩进半个键。
    /// - 有加宽键的行（shift/退格/123/空格）—— 键宽按权重铺满整行，
    ///   首尾键贴边（对标参考图 shift、123 都跟上面第一行对齐）。
    private func metrics(width: CGFloat) -> (unit: CGFloat, rowWidth: CGFloat) {
        let gap = KBMetrics.keyGap
        let span = CGFloat(max(keys.count - 1, 0))
        let sumW = keys.reduce(0) { $0 + $1.weight }
        let base = max(1, (width - gap * CGFloat(KeyboardLayout.canonicalKeys - 1))
                          / CGFloat(KeyboardLayout.canonicalKeys))
        let first = keys.first?.weight ?? 1
        let even = keys.allSatisfy { abs($0.weight - first) < 0.001 }
        var unit = even ? base : max(1, (width - gap * span) / max(sumW, 1))
        var rowW = sumW * unit + gap * span
        if rowW > width {
            // 用户把键调太宽了，退化成铺满一行，别溢出
            unit = max(1, (width - gap * span) / max(sumW, 1))
            rowW = width
        }
        return (unit, min(rowW, width))
    }

    @ViewBuilder
    private func keyView(_ spec: KeySpec) -> some View {
        switch spec.action {
        case .backspace:
            RepeatKey(spec: spec, onFire: { onKey(spec) }, onSwipeUp: onDeleteClear)
        case .space:
            SpaceKey(spec: spec, onTap: { onKey(spec) }, onMove: onSpaceMove)
        default:
            KeyCap(spec: spec,
                   onTap: { onKey(spec) },
                   onSwipe: { s in onSwipe(spec, s) },
                   onLongPress: { onLongPress(spec) })
        }
    }
}

/// 键盘顶栏（学百度输入法）：一行装下 LOGO / 候选词 / 功能入口 ——
///   左 = 软件图标   中 = 拼音串或候选词   右 = 剪贴板 / 思想库 / 收起
/// 功能栏不再单独占一条横（用户点名难看的那道横就是它），候选与功能同栏共存。
struct TopBar: View {

    let thoughtOn: Bool
    let clipboardOn: Bool
    /// 正在打拼音：右侧功能图标整组让位，候选词拉满整行（学百度）
    var typing: Bool = false
    let composing: String
    let candidates: [PinyinCandidate]
    let onPick: (PinyinCandidate) -> Void
    let onForget: (String) -> Void
    /// 长按候选：在该拼音下置顶 / 取消置顶（对标百度 PlumCore 的 ipt_set_firstword）
    let onPin: (String) -> Void
    /// 候选展开栏开着（按钮点亮 + 网格铺开）
    var expandOn: Bool = false
    /// 双拼角标：方案开启时常显（如「小鹤」），空串不显示
    var schemeBadge: String = ""
    /// 引擎角标：当前出字引擎（雾凇·30 / 自研兜底），常显，一眼看出在跑哪个引擎
    var engineBadge: String = ""
    let onToggleExpand: () -> Void
    let onClipboard: () -> Void
    let onThought: () -> Void
    let onThoughtLongPress: () -> Void
    let onCollapse: () -> Void

    /// 单行候选栏只摆 9 条（对标百度：6~9 条的干净横排，第一条加粗放大）。
    /// 早年摆 40 条，长词/整句候选混在一起一锅粥，正确候选反被冲淡。
    /// 更多的候选在展开网格（4x8）里一次看全，上滑选候选也按 1~9 对齐。
    private var shown: [PinyinCandidate] { Array(candidates.prefix(9)) }

    private var scale: CGFloat { KBMetrics.fontScale }

    var body: some View {
        let showPinyin = typing && !composing.isEmpty
        return VStack(spacing: 0) {
            if showPinyin { pinyinRow }
            barRow
        }
        .frame(height: KBMetrics.barHeight
               + (showPinyin ? KBMetrics.pinyinRowHeight : 0))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(KBMetrics.themeBarColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// 已输入的拼音：单独一行放在图标上方（学百度，不跟候选挤在一起）
    private var pinyinRow: some View {
        HStack(spacing: 0) {
            Text(composing)
                .font(.system(size: 14 * scale))
                .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .frame(height: KBMetrics.pinyinRowHeight)
    }

    private var barRow: some View {
        HStack(spacing: 0) {
            logo
            if !schemeBadge.isEmpty { badge }
            if !engineBadge.isEmpty { engineBadgeView }
            Group {
                if shown.isEmpty {
                    Text(composing)
                        .font(.system(size: 15 * scale))
                        .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.55))
                        .padding(.horizontal, 10)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            if composing.isEmpty {
                                Text("联想")
                                    .font(.system(size: 12 * scale))
                                    .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.55))
                                    .padding(.horizontal, 9)
                                divider
                            }
                            // 遍历 indices 再按下标取元素是经典崩溃源：候选数在
                            // 渲染途中变少（点字母/上屏/引擎异步回调），旧 indices
                            // 快照去取 shown[i] 就越界 → 扩展被打死 → iOS 立刻切回
                            // 上一个输入法，表现就是「点一下就跳走」。改成值捕获：
                            // 一次性快照 [(序号, 候选)]，闭包只用捕获到的候选本身。
                            let items = Array(shown.enumerated())
                            ForEach(items, id: \.offset) { pair in
                                let i = pair.offset
                                let c = pair.element
                                Text(c.word)
                                    .font(.system(size: (i == 0 ? 21 : 18) * scale,
                                                  weight: i == 0 ? .semibold : .regular))
                                    .foregroundColor(c.literal
                                                     ? KBMetrics.themeAccentColor.opacity(0.6)
                                                     : KBMetrics.themeCandidateTextColor)
                                    .padding(.horizontal, 9)
                                    .frame(height: KBMetrics.barHeight)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onPick(c) }
                                    .onLongPressGesture(minimumDuration: 0.45) {
                                        // 长按 = 置顶（再长按同一个词取消）。
                                        // 百度/搜狗都是这个操作，比「删除记忆」更常用。
                                        onPin(c.word)
                                    }
                                if i < items.count - 1 { divider }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // 展开候选栏：候选一键铺成网格 不用来回横滑
            if !shown.isEmpty {
                expandButton
            }

            if !typing {
                icon("doc.on.clipboard", active: clipboardOn,
                     tap: onClipboard, longPress: nil)
                icon("lightbulb", active: thoughtOn,
                     tap: onThought, longPress: onThoughtLongPress)
                icon("keyboard.chevron.compact.down", active: false,
                     tap: onCollapse, longPress: nil)
            }
        }
        .frame(height: KBMetrics.barHeight)
    }

    private var divider: some View {
        Rectangle()
            .fill(KBMetrics.themeCandidateTextColor.opacity(0.10))
            .frame(width: 0.5, height: 20)
    }

    /// 双拼角标：让用户随时看得见自己在哪个方案里
    /// （切了双拼又忘了，打出来的字母全是两键一音节，没个标识能急死人）
    private var badge: some View {
        Text(schemeBadge)
            .font(.system(size: 10 * scale, weight: .medium))
            .foregroundColor(KBMetrics.themeAccentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule().fill(KBMetrics.themeAccentColor.opacity(0.14)))
            .padding(.leading, 6)
            .fixedSize()
    }

    /// 引擎角标：雾凇就绪显主题色、自研兜底显橙，颜色直接暗示当前拼音质量档位
    private var engineBadgeView: some View {
        let isFallback = engineBadge.hasPrefix("自研")
        let tint = isFallback ? Color.orange : KBMetrics.themeAccentColor
        return Text(engineBadge)
            .font(.system(size: 10 * scale, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.16)))
            .padding(.leading, 6)
            .fixedSize()
    }

    private var logo: some View {
        Group {
            if let img = TopBar.logoImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "keyboard")
                    .font(.system(size: 18))
                    .foregroundColor(KBMetrics.themeSpecialTextColor)
            }
        }
        .frame(width: 26, height: 26)
        .padding(.leading, 9)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func icon(_ symbol: String, active: Bool,
                      tap: @escaping () -> Void,
                      longPress: (() -> Void)?) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(active ? .white : KBMetrics.themeSpecialTextColor.opacity(0.85))
            .frame(width: 37, height: KBMetrics.barHeight)
            .background(active ? KBMetrics.themeAccentColor : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { tap() }
            .onLongPressGesture(minimumDuration: 0.5) { longPress?() }
    }

    /// 展开候选栏按钮：展开后点亮，再点收起
    private var expandButton: some View {
        Image(systemName: expandOn ? "chevron.up" : "chevron.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(expandOn ? .white
                                      : KBMetrics.themeSpecialTextColor.opacity(0.85))
            .frame(width: 30, height: KBMetrics.barHeight)
            .background(expandOn ? KBMetrics.themeAccentColor : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpand() }
    }

    /// 软件图标：键盘 target 里随包带的 ime_logo.png
    private static let logoImage: UIImage? = {
        if let url = Bundle.main.url(forResource: "ime_logo", withExtension: "png"),
           let d = try? Data(contentsOf: url) {
            return UIImage(data: d)
        }
        return UIImage(named: "ime_logo")
    }()
}

/// 剪贴板面板：显示当前剪贴板内容，点一下整段上屏
struct ClipboardPanel: View {

    let text: String
    let onInsert: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14))
                .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.55))
            Text(text.isEmpty ? "剪贴板是空的" : text)
                .font(.system(size: 14))
                .lineLimit(1)
                .foregroundColor(text.isEmpty
                                 ? KBMetrics.themeCandidateTextColor.opacity(0.55)
                                 : KBMetrics.themeCandidateTextColor)
            Spacer(minLength: 6)
            if !text.isEmpty {
                Button("插入") { onInsert(text) }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(KBMetrics.themeAccentColor)
            }
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.45))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: KBMetrics.panelHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KBMetrics.themeKeyColor.opacity(0.92)))
    }
}

/// 思想库面板：跟百度「翻译」一样，点功能栏图标就在键盘上方冒出一个输入框。
/// 输入关键词 → 回车逐句输出（预览条显示下一句）。命中卡片列表已砍：
/// 回车就是输出，列出来再点属于重复操作，还白占键盘高度。
/// 注意：键盘扩展里没法再弹一个系统键盘，所以这个输入框的字符由键盘自己的键喂进来，
/// 这里只做展示（含闪烁光标），不做真正的 UITextField。
struct ThoughtPanel: View {

    let query: String
    let composing: String
    /// 预览条文案：下一条回车要输出的句子（没命中给提示）
    let preview: String
    /// 是否命中关键词（决定预览文案深浅）
    let previewHit: Bool
    let onClose: () -> Void

    @State private var caretOn = true

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.55))
                HStack(spacing: 0) {
                    Text(query)
                        .font(.system(size: 15))
                        .foregroundColor(KBMetrics.themeCandidateTextColor)
                    if !composing.isEmpty {
                        Text(composing)
                            .font(.system(size: 15))
                            .foregroundColor(KBMetrics.themeAccentColor)
                    }
                    Rectangle()
                        .fill(KBMetrics.themeAccentColor)
                        .frame(width: 1.5, height: 18)
                        .opacity(caretOn ? 1 : 0)
                }
                if query.isEmpty && composing.isEmpty {
                    Text("输入关键词…")
                        .font(.system(size: 15))
                        .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.55))
                }
                Spacer(minLength: 6)
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(KBMetrics.themeCandidateTextColor.opacity(0.45))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(KBMetrics.themeKeyColor.opacity(0.92)))

            // 预览条：下一条回车要输出哪句，进度一眼看清
            HStack(spacing: 6) {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundColor(previewHit
                                     ? KBMetrics.themeCandidateTextColor.opacity(0.8)
                                     : KBMetrics.themeCandidateTextColor.opacity(0.45))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 20)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(KBMetrics.themeBarColor))
        .onAppear {
            caretOn = true
            withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                caretOn.toggle()
            }
        }
    }
}

/// 展开候选栏：把单行横滑的候选铺成 4 x 8 网格，一次看全。
/// 点词直接上屏（思想库模式下落进面板输入框），打完/删光候选空了就自动收起。
struct CandidateGridPanel: View {

    let candidates: [PinyinCandidate]
    let onPick: (PinyinCandidate) -> Void

    private var shown: [PinyinCandidate] { Array(candidates.prefix(32)) }

    private var gridRows: [[PinyinCandidate]] {
        stride(from: 0, to: shown.count, by: 8).map {
            Array(shown[$0..<min($0 + 8, shown.count)])
        }
    }

    var body: some View {
        // 同 CandidateBar：gridRows 是计算属性，行数会随候选刷新变化。
        // 按下标取行/取元素会越界崩，改成一次性快照 + 值捕获。
        let allRows = gridRows
        return VStack(spacing: 6) {
            ForEach(Array(allRows.enumerated()), id: \.offset) { rp in
                let r = rp.offset
                let row = rp.element
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { cp in
                        let i = cp.offset
                        let c = cp.element
                        Text(c.word)
                            .font(.system(size: 16,
                                          weight: (r == 0 && i == 0) ? .semibold : .regular))
                            .foregroundColor(c.literal
                                             ? KBMetrics.themeAccentColor.opacity(0.6)
                                             : KBMetrics.themeCandidateTextColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .padding(.horizontal, 2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(c) }
                    }
                }
            }
        }
        .padding(8)
        .frame(height: KBMetrics.candidatePanelHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(KBMetrics.themeBarColor))
    }
}