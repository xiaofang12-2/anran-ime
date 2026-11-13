import SwiftUI
import UIKit

/// 主界面：SVIP 至尊版 · 纯本地输入法
///
/// 没有登录墙、没有账号、没有手机号、没有联网。装完打开就能用，
/// 所有词库 / 配置 / 学习记录都留在这台手机里。
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
                // 顶部一层很淡的金粉，让黑金底有纵深
                RadialGradient(colors: [ARTheme.gold.opacity(0.16), .clear],
                               center: .init(x: 0.5, y: 0.02),
                               startRadius: 0, endRadius: 420)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        hero
                        svipBadge
                        ARTheme.sectionTitle("引擎规格")
                        specCard
                        ARTheme.sectionTitle("至臻设置")
                        entriesCard
                        ARTheme.sectionTitle("本机同步")
                        localSyncCard
                        ARTheme.sectionTitle("")
                        aboutCard
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

    // MARK: - 引擎规格卡

    private var specCard: some View {
        ARTheme.card {
            specRow(icon: "sparkles", title: "双引擎整句输入",
                    detail: "librime 雾凇拼音 + 自研词图，商业级词库覆盖")
            arDivider()
            specRow(icon: "text.book.closed", title: "上下文语言模型",
                    detail: "整句候选按搭配打分，长句不用来回翻页")
            arDivider()
            specRow(icon: "lightbulb.fill", title: "本地联想 + 越用越懂你",
                    detail: "上屏联想、词频自学习，全部只存本机")
            arDivider()
            specRow(icon: "lock.shield", title: "零账号 · 零联网",
                    detail: "无密码无手机号，任何输入内容都不出手机")
        }
    }

    private func specRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(ARTheme.goldDeep)
                .frame(width: 30, height: 30)
                .background(Circle().fill(ARTheme.goldSoft.opacity(0.32)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(ARTheme.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(ARTheme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
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

    // MARK: - 本机同步卡

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
            Text("同设备毫秒级生效，键盘开着也能立刻刷新；全程走本机回环，不联网、不上传。")
                .font(.system(size: 11.5))
                .foregroundColor(ARTheme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        ARTheme.card {
            HStack {
                Text("版本")
                    .font(.system(size: 14))
                    .foregroundColor(ARTheme.ink)
                Spacer()
                Text("v0.9.62 SVIP Edition")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(ARTheme.goldDeep)
            }
            .padding(.vertical, 12)
            arDivider()
            HStack {
                Text("运行状态")
                    .font(.system(size: 14))
                    .foregroundColor(ARTheme.ink)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.20, green: 0.72, blue: 0.42)).frame(width: 7, height: 7)
                    Text("纯本地 · 已就绪")
                        .font(.system(size: 12.5))
                        .foregroundColor(ARTheme.inkSoft)
                }
            }
            .padding(.vertical, 12)
        }
    }
}
