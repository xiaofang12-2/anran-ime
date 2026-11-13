import SwiftUI

/// 冷启动欢迎礼遇：黑金开场 + 逐字金光标题「欢迎尊贵的 SVIP 贵宾」。
///
/// 只在主程序冷启动播一次（由 AnRanApp 的 scenePhase 控制），
/// 整个过程约 2.7 秒，点一下可立即跳过。纯本地、无网络、无账号。
struct SVIPWelcomeView: View {

    let onFinish: () -> Void

    @State private var appeared = false
    @State private var lettersIn = false
    @State private var rotating = false
    @State private var fading = false
    @State private var finished = false

    private let chars = Array("欢迎尊贵的 SVIP 贵宾")
    private let total: TimeInterval = 2.7

    var body: some View {
        ZStack {
            // 黑金底：深墨 → 暖黑，两团金色柔光
            LinearGradient(colors: [Color(red: 0.045, green: 0.043, blue: 0.055),
                                    Color(red: 0.105, green: 0.085, blue: 0.075),
                                    Color(red: 0.045, green: 0.043, blue: 0.055)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            RadialGradient(colors: [ARTheme.gold.opacity(0.26), .clear],
                           center: .init(x: 0.5, y: 0.38),
                           startRadius: 10, endRadius: 340)
                .ignoresSafeArea()
                .blur(radius: 12)

            // 细金尘：几枚静态光点，跟着整体一起淡入
            ForEach(Array(dust.enumerated()), id: \.offset) { _, p in
                Circle()
                    .fill(ARTheme.goldLight.opacity(p.opacity))
                    .frame(width: p.size, height: p.size)
                    .offset(x: p.x, y: p.y)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 1.1).delay(p.delay), value: appeared)
            }

            VStack(spacing: 22) {
                Spacer(minLength: 0)

                // 双层旋转金环 + 徽记
                ZStack {
                    Circle()
                        .stroke(LinearGradient(colors: [.clear, ARTheme.gold, .clear],
                                               startPoint: .leading, endPoint: .trailing),
                                lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .rotationEffect(.degrees(rotating ? 360 : 0))
                        .animation(.linear(duration: 7).repeatForever(autoreverses: false),
                                   value: rotating)
                    Circle()
                        .stroke(ARTheme.goldDeep.opacity(0.55), lineWidth: 1)
                        .frame(width: 106, height: 106)
                    Circle()
                        .fill(ARTheme.gold.opacity(0.10))
                        .frame(width: 96, height: 96)
                    Image(systemName: "rosette")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(ARTheme.goldLight)
                        .shadow(color: ARTheme.gold.opacity(0.8), radius: 14)
                }
                .scaleEffect(appeared ? 1 : 0.72)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.75, dampingFraction: 0.72), value: appeared)

                // 逐字金光标题
                HStack(spacing: 1.2) {
                    ForEach(Array(chars.enumerated()), id: \.offset) { i, ch in
                        Text(String(ch))
                            .font(.system(size: ch == " " ? 12 : 23,
                                         weight: .bold, design: .serif))
                            .foregroundColor(ARTheme.goldLight)
                            .shadow(color: ARTheme.gold.opacity(0.65), radius: 8, y: 1)
                            .opacity(lettersIn ? 1 : 0)
                            .offset(y: lettersIn ? 0 : 14)
                            .animation(.spring(response: 0.45, dampingFraction: 0.74)
                                        .delay(0.32 + Double(i) * 0.052),
                                       value: lettersIn)
                    }
                }
                .padding(.top, 6)

                Text("ANRAN  ·  至 臻 输 入 体 验")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(2.0)
                    .foregroundColor(ARTheme.goldLight.opacity(0.72))
                    .opacity(lettersIn ? 1 : 0)
                    .animation(.easeOut(duration: 0.7).delay(1.0), value: lettersIn)

                // 金线进度
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10)).frame(width: 168, height: 2)
                    Capsule()
                        .fill(LinearGradient(colors: [ARTheme.goldDeep, ARTheme.goldLight],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: appeared ? 168 : 0, height: 2)
                        .animation(.easeInOut(duration: total - 0.3), value: appeared)
                }
                .padding(.top, 8)

                Spacer(minLength: 0)

                Text("SVIP 至尊礼遇  ·  纯本地  ·  免登录")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.42))
                    .padding(.bottom, 44)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(fading ? 0 : 1)
        .animation(.easeInOut(duration: 0.45), value: fading)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .onAppear { play() }
    }

    // MARK: - 动画时序

    private func play() {
        withAnimation { appeared = true }
        rotating = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            lettersIn = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total - 0.45) {
            fading = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + total) {
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    // MARK: - 金尘坐标（固定，不用随机数：每次重绘位置稳定）

    private struct Dust {
        let x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double, delay: Double
    }

    private var dust: [Dust] {
        [Dust(x: -148, y: -232, size: 3, opacity: 0.75, delay: 0.10),
         Dust(x: 132, y: -186, size: 2, opacity: 0.60, delay: 0.24),
         Dust(x: -112, y: -96, size: 2, opacity: 0.50, delay: 0.38),
         Dust(x: 156, y: 46, size: 3, opacity: 0.65, delay: 0.46),
         Dust(x: -160, y: 122, size: 2, opacity: 0.45, delay: 0.58),
         Dust(x: 96, y: 208, size: 3, opacity: 0.70, delay: 0.66),
         Dust(x: -62, y: 258, size: 2, opacity: 0.40, delay: 0.78)]
    }
}
