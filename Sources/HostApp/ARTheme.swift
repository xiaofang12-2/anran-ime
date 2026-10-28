import SwiftUI
import UIKit

/// 主程序主题件：「樱花玻璃」——樱花粉 → 薰衣草紫的对角渐变底，
/// 白色半透明立体卡片 + 粉调柔光阴影，控件统一圆角与高光。
/// 设置里的每一页都从这套件里取料，风格永远统一。
enum ARTheme {

    // MARK: - 樱花色板

    /// 主粉（按钮/强调）
    static let sakura = Color(red: 1.00, green: 0.560, blue: 0.700)        // #FF8FB3
    /// 深粉（按下/描边/导航）
    static let sakuraDeep = Color(red: 0.937, green: 0.435, blue: 0.616)   // #EF6F9D
    /// 浅粉（光斑/底纹）
    static let sakuraLight = Color(red: 1.00, green: 0.780, blue: 0.855)   // #FFC7DA
    /// 薰衣草紫
    static let lav = Color(red: 0.718, green: 0.545, blue: 1.00)           // #B78BFF
    static let lavDeep = Color(red: 0.596, green: 0.412, blue: 0.910)      // #9869E8
    /// 卡片上的深色文字
    static let ink = Color(red: 0.29, green: 0.18, blue: 0.24)             // #4A2E3D
    static let inkSoft = Color(red: 0.54, green: 0.39, blue: 0.47)

    // 兼容旧名（别处还引用着）
    static let navy = sakuraDeep
    static let blue = sakura
    static let blueLight = sakuraLight

    /// 主页面背景：樱花粉 → 薰衣草紫 对角渐变 + 两团柔光
    static var background: some View {
        ZStack {
            LinearGradient(colors: [sakura, lav],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.38), .clear],
                           center: .init(x: 0.16, y: 0.06),
                           startRadius: 0, endRadius: 300)
            RadialGradient(colors: [sakuraLight.opacity(0.45), .clear],
                           center: .init(x: 0.92, y: 0.88),
                           startRadius: 0, endRadius: 340)
        }
        .ignoresSafeArea()
    }

    /// 设置子页背景：浅樱底（List 的深色标题在这种底上读得清）
    static var softBackground: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1.00, green: 0.965, blue: 0.980),
                                    Color(red: 0.972, green: 0.945, blue: 1.00)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [sakuraLight.opacity(0.30), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    /// 白色立体卡片（粉调柔光 + 顶部高光描边）
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(LinearGradient(
                                colors: [Color.white.opacity(0.95),
                                         sakuraLight.opacity(0.55)],
                                startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1))
                    .shadow(color: sakuraDeep.opacity(0.20), radius: 18, y: 8)
                    .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2))
    }

    /// 分区标题（彩色底上的白字小标）
    static func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(.white.opacity(0.88))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .shadow(color: sakuraDeep.opacity(0.35), radius: 3, y: 1)
    }

    /// 全局安装：系统 List 的底透明化（子页渐变能透出来），导航条统一成樱花粉
    static func install() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(sakuraDeep)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = .white

        // 系统控件统一粉色
        UISwitch.appearance().onTintColor = UIColor(sakuraDeep)
        UISlider.appearance().minimumTrackTintColor = UIColor(sakuraDeep)
        UIStepper.appearance().tintColor = UIColor(sakuraDeep)
    }
}

// MARK: - 卡片里的行组件

/// 基础行：左标题(+副标题) 右侧任意控件，行间用细线隔开
struct ARRow<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(ARTheme.ink.opacity(0.88))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(ARTheme.inkSoft)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 11)
    }
}

extension View {
    /// 卡片内行与行之间的细线
    func arDivider() -> some View {
        Divider().opacity(0.10)
    }
}

/// 开关行：标题 + 右侧 Toggle
struct ARToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(ARTheme.ink.opacity(0.88))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(ARTheme.sakuraDeep)
                .fixedSize()
        }
        .padding(.vertical, 9)
    }
}

/// 步进行
struct ARStepperRow: View {
    let title: String
    let valueText: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    /// 标题下方的小字说明（可选）
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(ARTheme.ink.opacity(0.88))
                Spacer()
                Text(valueText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(ARTheme.sakuraDeep)
                Stepper("", value: $value, in: range)
                    .labelsHidden()
                    .tint(ARTheme.sakuraDeep)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(ARTheme.inkSoft)
            }
        }
        .padding(.vertical, 9)
    }
}

/// 数字输入行：标题 + 数字输入框（失焦时夹回范围）
struct ARNumberFieldRow: View {
    let title: String
    var suffix: String = ""
    let range: ClosedRange<Int>
    @Binding var value: Int

    @State private var raw = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(ARTheme.ink.opacity(0.88))
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                TextField("", text: $raw)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(ARTheme.ink)
                    .frame(width: 52)
                    .focused($focused)
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.system(size: 11))
                        .foregroundColor(ARTheme.inkSoft)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ARTheme.sakuraLight.opacity(0.22)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ARTheme.sakuraLight.opacity(0.65), lineWidth: 1))
            .onAppear { raw = String(value) }
            .onChange(of: raw) { _ in commit() }
            .onChange(of: focused) { f in
                if !f { raw = String(value) }
            }
            .onChange(of: value) { v in
                if !focused { raw = String(v) }
            }
        }
        .padding(.vertical, 9)
    }

    private func commit() {
        guard let n = Int(raw.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = min(max(n, range.lowerBound), range.upperBound)
        if clamped != value { value = clamped }
    }
}

/// 推进页的整行入口（自带小箭头 整行可点）
struct ARNavRow<Destination: View>: View {
    let title: String
    var icon: String = "chevron.right"
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundColor(ARTheme.ink.opacity(0.88))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ARTheme.sakura.opacity(0.65))
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 动作行（按钮）：label 自定义颜色
struct ARActionRow: View {
    let title: String
    var icon: String? = nil
    var tint: Color = ARTheme.ink.opacity(0.88)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                }
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundColor(tint)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 系统List子页套壳：透明底 + 浅色渐变

extension View {
    /// 给仍是系统 List 的设置子页统一上浅色渐变底（iOS16+ 去掉 List 自带白底）
    @ViewBuilder
    func arListPage() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
                .background(ARTheme.softBackground)
        } else {
            self.background(ARTheme.softBackground)
        }
    }

    /// 弹层半屏吸附（iOS15 无此API 自动退化成全高弹层）
    @ViewBuilder
    func arMediumSheet() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium])
        } else {
            self
        }
    }
}

/// 主页面大按钮（樱花渐变胶囊 + 高光）
struct ARPrimaryButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(1.2)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [ARTheme.sakura, ARTheme.sakuraDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: ARTheme.sakuraDeep.opacity(0.45), radius: 14, y: 7)
                    .shadow(color: Color.white.opacity(0.30), radius: 1, y: -1))
        }
        .buttonStyle(.plain)
    }
}
