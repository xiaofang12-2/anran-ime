import SwiftUI
import UIKit

/// 主程序主题件：「简约立体」深蓝渐变底 + 白色悬浮卡片，登录墙同款配色铺满设置，
/// 彻底告别 iOS 系统白灰 List。设置里的每一页都从这套件里取料，风格永远统一。
enum ARTheme {

    static let navy = Color(red: 0.10, green: 0.14, blue: 0.34)
    static let blue = Color(red: 0.23, green: 0.43, blue: 0.94)
    static let blueLight = Color(red: 0.36, green: 0.58, blue: 1.0)

    /// 主页面背景：登录墙同款对角渐变
    static var background: some View {
        LinearGradient(colors: [navy, blue],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }

    /// 设置子页背景：浅色底（List 的默认深色标题在这种底上才读得清）
    static var softBackground: some View {
        LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 1.0),
                                Color(red: 0.88, green: 0.91, blue: 0.99)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    /// 白色立体卡片
    static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 6))
    }

    /// 分区标题（白底页上的深色小标）
    static func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white.opacity(0.78))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)
    }

    /// 全局安装：系统 List 的底透明化（子页渐变能透出来），导航条统一成深蓝
    static func install() {
        UITableView.appearance().backgroundColor = .clear
        UICollectionView.appearance().backgroundColor = .clear

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(navy)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = .white
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
                    .foregroundColor(.black.opacity(0.85))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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
        Divider().opacity(0.1)
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
                .foregroundColor(.black.opacity(0.85))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(ARTheme.blue)
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
                    .foregroundColor(.black.opacity(0.85))
                Spacer()
                Text(valueText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                Stepper("", value: $value, in: range)
                    .labelsHidden()
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
                .foregroundColor(.black.opacity(0.85))
            Spacer(minLength: 8)
            HStack(spacing: 3) {
                TextField("", text: $raw)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(width: 52)
                    .focused($focused)
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.055)))
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
                    .foregroundColor(.black.opacity(0.85))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black.opacity(0.25))
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
    var tint: Color = .black.opacity(0.85)
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

/// 主页面大按钮（蓝渐变立体）
struct ARPrimaryButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [ARTheme.blue, ARTheme.blueLight],
                                         startPoint: .leading, endPoint: .trailing))
                    .shadow(color: ARTheme.blue.opacity(0.4), radius: 10, y: 5))
        }
        .buttonStyle(.plain)
    }
}
