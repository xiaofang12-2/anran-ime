import SwiftUI
import UIKit

/// 键帽样式：白键 + 底部 1px 投影，按下变灰、弹起复原（对标 iOS/百度手感）
struct KeyCapStyle: ButtonStyle {
    let spec: KeySpec

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return ZStack {
            RoundedRectangle(cornerRadius: KBMetrics.corner, style: .continuous)
                .fill(fill(pressed))
                .shadow(color: .black.opacity(0.30), radius: 0, x: 0, y: 1)
            configuration.label
        }
        .scaleEffect(pressed && !spec.special ? 0.96 : 1)
        .overlay(alignment: .top) {
            if pressed && spec.popup {
                Text(spec.label)
                    .font(.system(size: 28))
                    .foregroundColor(.black)
                    .frame(width: 42, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.28),
                                    radius: 4, x: 0, y: 2))
                    .offset(y: -50)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(pressed ? 20 : 0)
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

struct KeyCap: View {
    let spec: KeySpec
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(spec.label)
                .font(.system(size: spec.special ? 17 : 22))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(KeyCapStyle(spec: spec))
    }
}

/// 退格键：按下即删，按住连删
struct RepeatKey: View {
    let spec: KeySpec
    let onFire: () -> Void

    @State private var pressed = false
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
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        Haptics.tap()
                        onFire()
                        startRepeating()
                    }
                }
                .onEnded { _ in
                    pressed = false
                    stopRepeating()
                }
        )
        .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        stopRepeating()
        timer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { _ in
            onFire()
        }
    }

    private func stopRepeating() {
        timer?.invalidate()
        timer = nil
    }
}

/// 一行键位：按权重分宽度
struct KeyRow: View {
    let keys: [KeySpec]
    let onKey: (KeySpec) -> Void

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
        if case .backspace = spec.action {
            RepeatKey(spec: spec) { onKey(spec) }
        } else {
            KeyCap(spec: spec) { onKey(spec) }
        }
    }
}

/// 候选栏：拼音串在左，候选词往后排，点一下就上屏
struct CandidateBar: View {
    let composing: String
    let candidates: [PinyinCandidate]
    let onPick: (String) -> Void

    private var shown: [PinyinCandidate] { Array(candidates.prefix(30)) }

    var body: some View {
        Group {
            if composing.isEmpty {
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
                        Text(composing)
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 10)
                        ForEach(shown.indices, id: \.self) { i in
                            Button(action: { onPick(shown[i].word) }) {
                                Text(shown[i].word)
                                    .font(.system(size: 19))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 10)
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
}

enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)

    static func tap() {
        light.impactOccurred()
    }
}