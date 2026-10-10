import SwiftUI
import UIKit

/// 触感反馈：字母轻震、功能键重一点
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)

    static func tap() { light.impactOccurred() }
    static func bump() { medium.impactOccurred() }
}

/// 按键音（对标系统键盘，默认开）
enum KeySound {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "anran_kb_sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "anran_kb_sound") }
    }

    static func play() {
        if enabled { UIDevice.current.playInputClick() }
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
            VStack(spacing: 0) {
                Text(spec.label)
                    .font(.system(size: spec.special ? 17 : (spec.sub != nil ? 20 : 22)))
                    .foregroundColor(.black)
                if let sub = spec.sub {
                    Text(sub)
                        .font(.system(size: 9))
                        .foregroundColor(.black.opacity(0.5))
                }
            }
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
                        Haptics.tap()
                        KeySound.play()
                    }
                    if let s = spec.swipe, v.translation.height < -28 {
                        consumed = true
                        pressed = false
                        Haptics.bump()
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
                        Haptics.bump()
                        onSwipeUp?()
                        return
                    }
                    if !pressed {
                        pressed = true
                        Haptics.tap()
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
                        Haptics.tap()
                        KeySound.play()
                    }
                    if abs(v.translation.width) > 24 {
                        consumed = true
                        let steps = Int(v.translation.width / 24)
                        if steps != 0 {
                            Haptics.bump()
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

/// 候选栏：拼音串/「联想」在左，候选往后排，首个候选加重
struct CandidateBar: View {
    let composing: String
    let candidates: [PinyinCandidate]
    let onPick: (String) -> Void

    private var shown: [PinyinCandidate] { Array(candidates.prefix(30)) }

    var body: some View {
        Group {
            if shown.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    Text("思想库（阶段 2 接上）")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Text(composing.isEmpty ? "联想" : composing)
                            .font(.system(size: composing.isEmpty ? 12 : 15))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        divider
                        ForEach(shown.indices, id: \.self) { i in
                            Button(action: { onPick(shown[i].word) }) {
                                HStack(spacing: 0) {
                                    Text(shown[i].word)
                                        .font(.system(size: i == 0 ? 21 : 19,
                                                      weight: i == 0 ? .semibold : .regular))
                                        .foregroundColor(shown[i].literal
                                                         ? Color(red: 0.34, green: 0.38, blue: 0.46)
                                                         : .black)
                                        .padding(.horizontal, 10)
                                    if i < shown.count - 1 { divider }
                                }
                                .frame(height: KBMetrics.barHeight)
                            }
                            .buttonStyle(.plain)
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