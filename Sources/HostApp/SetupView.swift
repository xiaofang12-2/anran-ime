import SwiftUI
import UIKit

/// 主界面：只放设置入口与本机同步。
/// 不展示引擎规格、运行诊断、版本说明 —— 输入法好不好用跟这些没关系。
struct SetupView: View {

    /// 键盘功能栏点图标/长按跳过来时，程序化推对应设置页
    @State private var goPhrases = false
    @State private var goThoughts = false
    @State private var goBrush = false
    @State private var syncDone = false
    @State private var syncPulse = false

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            ZStack {
                ARTheme.background
                RadialGradient(colors: [ARTheme.gold.opacity(0.16), .clear],
                               center: .init(x: 0.5, y: 0.02),
                               startRadius: 0, endRadius: 420)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        hero
                        svipBadge
                        ARTheme.sectionTitle("设置")
                        entriesCard
                        ARTheme.sectionTitle("同步")
                        localSyncCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
        .onReceive(NotificationCenter.default.publisher(for: ConfigSync.localStoreChanged)) { _ in
            _ = ConfigSync.publishIfChanged()
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                _ = ConfigSync.publishIfChanged()
                ConfigSync.flushPending()
            } else {
                ConfigSync.publishIfChanged()
            }
        }
        .onOpenURL { url in
            switch url.host {
            case "phrases": goPhrases = true
            case "thoughts": goThoughts = true
            case "brush": goBrush = true
            default: break
            }
        }
    }

    // MARK: - 头部

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(ARTheme.goldSoft.opacity(0.16))
                    .frame(width: 96, height: 96)
                    .blur(radius: 14)
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(LinearGradient(colors: [ARTheme.goldLight, ARTheme.gold],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 76, height: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.45), lineWidth: 1))
                    .shadow(color: ARTheme.gold.opacity(0.45), radius: 18, y: 8)
                Image(systemName: "keyboard")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(ARTheme.ink)
            }
            Text("黯然输入法")
                .font(.system(size: 27, weight: .bold, design: .serif))
                .foregroundColor(.white)
                .shadow(color: ARTheme.gold.opacity(0.35), radius: 8, y: 2)
            Text("ANRAN  ·  PREMIUM INPUT")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(2.4)
                .foregroundColor(ARTheme.goldLight.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var svipBadge: some View {
        HStack(spacing: 9) {
            Image(systemName: "rosette")
                .font(.system(size: 13))
                .foregroundColor(ARTheme.ink)
            Text("SVIP 至尊贵宾")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(ARTheme.ink)
            Spacer(minLength: 4)
            Text("永久 · 免登录")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ARTheme.ink.opacity(0.72))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Capsule(style: .continuous)
                .fill(LinearGradient(colors: [ARTheme.goldLight, ARTheme.gold, ARTheme.goldDeep],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.4), lineWidth: 1))
                .shadow(color: ARTheme.gold.opacity(0.35), radius: 12, y: 5))
        .padding(.horizontal, 22)
        .padding(.bottom, 4)
    }

    // MARK: - 设置入口卡

    private var entriesCard: some View {
        ARTheme.card {
            ARNavRow(title: "输入设置") { SettingsView() }
            arDivider()
            ARNavRow(title: "键盘布局") { LayoutSettingsView() }
            arDivider()
            ARNavRow(title: "皮肤主题") { SkinSettingsView() }
            arDivider()
            NavigationLink(destination: PhraseSettingsView(), isActive: $goPhrases) {
                navLabel("自定义短语")
            }
            .buttonStyle(.plain)
            arDivider()
            NavigationLink(destination: ThoughtSettingsView(), isActive: $goThoughts) {
                navLabel("思想库")
            }
            .buttonStyle(.plain)
            arDivider()
            NavigationLink(destination: BrushSettingsView(), isActive: $goBrush) {
                navLabel("刷天帝")
            }
            .buttonStyle(.plain)
        }
    }

    private func navLabel(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(ARTheme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ARTheme.goldDeep.opacity(0.75))
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    // MARK: - 本机同步

    private var localSyncCard: some View {
        ARTheme.card {
            ARPrimaryButton(title: syncDone ? "已同步到键盘 ✓" : "立即同步到键盘",
                            busy: syncPulse) {
                syncPulse = true
                _ = ConfigSync.publish()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    syncPulse = false
                    syncDone = true
                }
            }
            .padding(.vertical, 12)
        }
    }
}
