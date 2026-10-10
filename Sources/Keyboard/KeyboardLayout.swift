import SwiftUI

/// 键盘层
enum KBLayer {
    case letters, numbers, symbols
}

/// 一个键的动作
enum KeyAction {
    case letter(String)      // 字母（吃 shift 影响）
    case text(String)        // 直接上屏的符号
    case shift
    case backspace
    case space
    case ret
    case globe
    case toLayer(KBLayer)
}

struct KeySpec: Identifiable {
    let id: String
    let label: String
    let weight: CGFloat
    let action: KeyAction
    let special: Bool
    let popup: Bool
    let active: Bool

    init(_ id: String, _ label: String, _ weight: CGFloat,
         _ action: KeyAction, special: Bool = false,
         popup: Bool = false, active: Bool = false) {
        self.id = id
        self.label = label
        self.weight = weight
        self.action = action
        self.special = special
        self.popup = popup
        self.active = active
    }
}

/// 尺寸常量，对标 iOS 原生键盘（百度输入法同一套骨架）
enum KBMetrics {
    static let rowGap: CGFloat = 6
    static let keyGap: CGFloat = 6
    static let sideInset: CGFloat = 3
    static let keyHeight: CGFloat = 42
    static let barHeight: CGFloat = 44
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 4
    static let corner: CGFloat = 5

    static var totalHeight: CGFloat {
        topInset + barHeight + rowGap + keyHeight * 4 + rowGap * 3 + bottomInset
    }
}

enum KeyboardLayout {

    private static let letterRow1 = Array("qwertyuiop")
    private static let letterRow2 = Array("asdfghjkl")
    private static let letterRow3 = Array("zxcvbnm")

    static func rows(layer: KBLayer, shift: Bool) -> [[KeySpec]] {
        switch layer {
        case .letters: return letterRows(shift: shift)
        case .numbers: return numberRows
        case .symbols: return symbolRows
        }
    }

    static func letterRows(shift: Bool) -> [[KeySpec]] {
        var out: [[KeySpec]] = []
        out.append(letterRow1.map { KeySpec("L\($0)", String($0).uppercased(), 1,
                                            .letter(String($0)), popup: true) })
        out.append(letterRow2.map { KeySpec("L\($0)", String($0).uppercased(), 1,
                                            .letter(String($0)), popup: true) })
        var r3: [KeySpec] = [KeySpec("shift", "⇧", 1.4, .shift,
                                     special: true, active: shift)]
        r3 += letterRow3.map { KeySpec("L\($0)", String($0).uppercased(), 1,
                                       .letter(String($0)), popup: true) }
        r3.append(KeySpec("backspace", "⌫", 1.4, .backspace, special: true))
        out.append(r3)
        out.append(bottomRow(leading: KeySpec("to123", "123", 1.5, .toLayer(.numbers),
                                              special: true)))
        return out
    }

    static var numberRows: [[KeySpec]] {
        let r1 = Array("1234567890")
        let r2 = Array("-/:;()¥&@\"")
        return [
            r1.map { KeySpec("N\($0)", String($0), 1, .text(String($0)), popup: true) },
            r2.map { KeySpec("N\($0)", String($0), 1, .text(String($0)), popup: true) },
            symbolRow3(leading: KeySpec("toSym", "#+=", 1.4, .toLayer(.symbols), special: true)),
            bottomRow(leading: KeySpec("toABC", "ABC", 1.5, .toLayer(.letters), special: true)),
        ]
    }

    static var symbolRows: [[KeySpec]] {
        let r1 = Array("[]{}#%^*+=")
        let r2 = Array("_\\|~<>€£¥•")
        return [
            r1.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            r2.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            symbolRow3(leading: KeySpec("to123", "123", 1.4, .toLayer(.numbers), special: true)),
            bottomRow(leading: KeySpec("toABC", "ABC", 1.5, .toLayer(.letters), special: true)),
        ]
    }

    /// 数字/符号层的第三行：. , ? ! ' + 退格
    private static func symbolRow3(leading: KeySpec) -> [KeySpec] {
        var r: [KeySpec] = [leading]
        for ch in [".", ",", "?", "!", "'"] {
            r.append(KeySpec("P\(ch)", ch, 1, .text(ch), popup: true))
        }
        r.append(KeySpec("backspace", "⌫", 1.4, .backspace, special: true))
        return r
    }

    /// 第四行：层切换键 + 地球 + 空格 + 换行
    private static func bottomRow(leading: KeySpec) -> [KeySpec] {
        [
            leading,
            KeySpec("globe", "🌐", 1.3, .globe, special: true),
            KeySpec("space", "空格", 5, .space, special: true),
            KeySpec("ret", "换行", 1.8, .ret, special: true),
        ]
    }
}