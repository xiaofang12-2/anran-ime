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

/// 普通键帽：白底 + 底部 1px 投影，按下变灰缩放，上滑可打出副字符
struct KeyCap: View {
    let spec: KeySpec
    let onTap: () -> Void
    var onSwipe: ((String) -> Void)? = nil

    @State private var pressed = false
    @State private var consumed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(fill(pressed))
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            Text(spec.label)
                .font(.system(size: (spec.special ? 17 : 22) * KBMetrics.fontScale))
                .foregroundColor(.black)
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
                    }
                    if let s = spec.swipe, v.translation.height < -28 {
                        consumed = true
                        pressed = false
                        onSwipe?(s)
                    }
                }
                .onEnded { v in
                    if consumed { consumed = false; return }
                    let was = pressed
                    pressed = false
                    if was && v.translation.height > -28 { onTap() }
                }
        )
    }

    private var bubble: some View {
        Text(spec.label)
            .font(.system(size: 28))
            .foregroundColor(.black)
            .frame(width: 42, height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 2))
            .offset(y: -50)
            .allowsHitTesting(false)
    }

    private func fill(_ pressed: Bool) -> Color {
        if spec.active { return .white }
        if spec.special {
            return pressed ? Color(white: 0.60)
                           : Color(red: 0.68, green: 0.70, blue: 0.74)
        }
        return pressed ? Color(white: 0.72) : .white
    }
}

/// 退格键：按下即删，按住连删，上滑清空整串
struct RepeatKey: View {
    let spec: KeySpec
    let onFire: () -> Void
    var onSwipeUp: (() -> Void)? = nil

    @State private var pressed = false
    @State private var consumed = false
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(pressed ? Color(white: 0.60)
                              : Color(red: 0.68, green: 0.70, blue: 0.74))
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            Text(spec.label)
                .font(.system(size: 20))
                .foregroundColor(.black)
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
                        start()
                    }
                }
                .onEnded { _ in
                    consumed = false
                    stop()
                }
        )
        .onDisappear { stop() }
    }

    private func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
            onFire()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pressed = false
    }
}

/// 空格键：点一下上屏/空格，左右滑动移动光标
struct SpaceKey: View {
    let spec: KeySpec
    let onTap: () -> Void
    let onMove: (Int) -> Void

    @State private var pressed = false
    @State private var consumed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(pressed ? Color(white: 0.60)
                              : Color(red: 0.68, green: 0.70, blue: 0.74))
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            Text(spec.label)
                .font(.system(size: 15))
                .foregroundColor(.black)
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

/// 一行键位：按权重分宽度
struct KeyRow: View {
    let keys: [KeySpec]
    let onKey: (KeySpec) -> Void
    let onSwipe: (KeySpec, String) -> Void
    let onDeleteClear: () -> Void
    let onSpaceMove: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let total = keys.reduce(0) { $0 + $1.weight }
            let gaps = KBMetrics.keyGap * CGFloat(max(keys.count - 1, 0))
            let unit = max(1, (geo.size.width - gaps) / total)
            HStack(spacing: KBMetrics.keyGap) {
                ForEach(keys) { spec in
                    keyView(spec)
                        .frame(width: unit * spec.weight)
                }
            }
        }
        .frame(height: KBMetrics.keyHeight)
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
                   onSwipe: { s in onSwipe(spec, s) })
        }
    }
}

/// 候选栏：只有「拼音串 + 候选」两样，不放任何功能键（数字、思想库都不占这儿）。
/// 长按某个候选 = 把它从用户词频里抹掉（自己纠错，对标百度的「删除记忆」）。
struct CandidateBar: View {
    let composing: String
    let candidates: [PinyinCandidate]
    let onPick: (PinyinCandidate) -> Void
    let onForget: (String) -> Void

    private var shown: [PinyinCandidate] { Array(candidates.prefix(40)) }

    private var scale: CGFloat { KBMetrics.fontScale }

    var body: some View {
        HStack(spacing: 0) {
            if shown.isEmpty {
                // 没候选就一条空栏，只把正在打的拼音串露出来，别的不占位
                Text(composing)
                    .font(.system(size: 15 * scale))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Text(composing.isEmpty ? "联想" : composing)
                            .font(.system(size: (composing.isEmpty ? 12 : 15) * scale))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        divider
                        ForEach(shown.indices, id: \.self) { i in
                            Text(shown[i].word)
                                .font(.system(size: (i == 0 ? 22 : 19) * scale,
                                              weight: i == 0 ? .semibold : .regular))
                                .foregroundColor(shown[i].literal
                                                 ? Color(red: 0.34, green: 0.38, blue: 0.46)
                                                 : .black)
                                .padding(.horizontal, 11)
                                .frame(height: KBMetrics.barHeight)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(shown[i]) }
                                .onLongPressGesture(minimumDuration: 0.45) {
                                    onForget(shown[i].word)
                                }
                            if i < shown.count - 1 { divider }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: KBMetrics.barHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.65)))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.10))
            .frame(width: 0.5, height: 20)
    }
}