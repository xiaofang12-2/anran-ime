import SwiftUI

/// 键盘界面
///
/// 阶段 0 版本：26 键英文布局 + 顶部横栏占位。
/// 顶部那条横栏就是阶段 2 要放「思想库」的位置（对标百度输入法开翻译后那条）。
struct KeyboardRootView: View {

    let controller: KeyboardViewController

    private let letterRows: [[KeySpec]] = [
        "qwertyuiop".map { KeySpec(char: String($0)) },
        "asdfghjkl".map { KeySpec(char: String($0)) },
        "zxcvbnm".map { KeySpec(char: String($0)) },
    ]

    var body: some View {
        VStack(spacing: 7) {
            toolbar
            ForEach(letterRows.indices, id: \.self) { i in
                KeyRow(keys: letterRows[i]) { spec in
                    if let c = spec.char { controller.insert(c) }
                }
            }
            bottomRow
        }
        .padding(.horizontal, 4)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Color(red: 0.82, green: 0.83, blue: 0.85))
    }

    /// 顶部横栏 —— 阶段 2 换成真正的「思想库」输入框
    private var toolbar: some View {
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
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.65)))
    }

    private var bottomRow: some View {
        KeyRow(keys: [
            KeySpec(label: "🌐", weight: 1.3, kind: .globe),
            KeySpec(label: "空格", weight: 5.0, kind: .space),
            KeySpec(label: "⌫", weight: 1.3, kind: .backspace),
            KeySpec(label: "换行", weight: 1.5, kind: .ret),
        ]) { spec in
            switch spec.kind {
            case .globe:     controller.advanceToNextInputMode()
            case .space:     controller.insert(" ")
            case .backspace: controller.backspace()
            case .ret:       controller.newline()
            case .char:      break
            }
        }
    }
}

// MARK: - 键位模型

struct KeySpec: Identifiable {
    enum Kind { case char, space, backspace, ret, globe }

    let id = UUID()
    let label: String
    let weight: CGFloat
    let kind: Kind
    let char: String?

    init(char: String) {
        self.label = char.uppercased()
        self.weight = 1
        self.kind = .char
        self.char = char
    }

    init(label: String, weight: CGFloat, kind: Kind) {
        self.label = label
        self.weight = weight
        self.kind = kind
        self.char = nil
    }
}

// MARK: - 一行键位（按权重分宽度）

struct KeyRow: View {
    let keys: [KeySpec]
    let onTap: (KeySpec) -> Void

    private let gap: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let total = keys.reduce(0) { $0 + $1.weight }
            let unit = (geo.size.width
                        - gap * CGFloat(max(keys.count - 1, 0))) / total
            HStack(spacing: gap) {
                ForEach(keys) { spec in
                    KeyCap(label: spec.label) { onTap(spec) }
                        .frame(width: unit * spec.weight)
                }
            }
        }
        .frame(height: 44)
    }
}

struct KeyCap: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 20))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.28),
                                radius: 0, x: 0, y: 1))
        }
        .buttonStyle(.plain)
    }
}
