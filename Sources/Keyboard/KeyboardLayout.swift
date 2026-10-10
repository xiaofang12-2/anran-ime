import SwiftUI

/// 键盘层：字母 / 数字 / 符号，三层靠布局里的「123」「ABC」「#+=」键互切
enum KBLayer {
    case letters, numbers, symbols
}

/// 一个键的动作
enum KeyAction {
    case letter(String)      // 字母键（吃 shift 影响）
    case text(String)        // 直接上屏的符号/数字
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
    /// 上滑这个键会打出的字符（对标百度：字母键上滑出数字）
    let swipe: String?

    init(_ id: String, _ label: String, _ weight: CGFloat,
         _ action: KeyAction, special: Bool = false,
         popup: Bool = false, active: Bool = false,
         swipe: String? = nil) {
        self.id = id
        self.label = label
        self.weight = weight
        self.action = action
        self.special = special
        self.popup = popup
        self.active = active
        self.swipe = swipe
    }
}

/// 尺寸常量，对标 iOS 原生键盘（百度输入法同一套骨架）。
/// 具体数值来自用户在「键盘布局」里调的 KBConfig，键高比原生略抬一点，
/// 手指落点更松，连打不易误触。
enum KBMetrics {
    /// 当前生效的配置，主程序改了、键盘接过来就换
    static var cfg: KBConfig = KBConfigStore.current

    static var rowGap: CGFloat { CGFloat(cfg.rowGap) }
    static var keyGap: CGFloat { CGFloat(cfg.keyGap) }
    static var sideInset: CGFloat { CGFloat(cfg.sideInset) }
    static var keyHeight: CGFloat { CGFloat(cfg.keyHeight) }
    static var corner: CGFloat { CGFloat(cfg.corner) }
    static var bottomInset: CGFloat { CGFloat(cfg.bottomInset) }
    static var fontScale: CGFloat { CGFloat(cfg.fontScale) }

    static let barHeight: CGFloat = 45
    static let topInset: CGFloat = 6

    /// 字母/数字/符号三层都是 4 行
    static let rows = 4

    static func totalHeight(rows: Int) -> CGFloat {
        topInset + barHeight + rowGap
            + keyHeight * CGFloat(rows)
            + rowGap * CGFloat(max(rows - 1, 0))
            + bottomInset
    }
}

enum KeyboardLayout {

    private static let letterRow1 = Array("qwertyuiop")
    private static let letterRow2 = Array("asdfghjkl")
    private static let letterRow3 = Array("zxcvbnm")

    /// 字母键上滑出对应数字
    private static let letterSwipe: [Character: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
        "a": "1", "s": "2", "d": "3", "f": "4", "g": "5",
        "h": "6", "j": "7", "k": "8", "l": "9",
        "z": "1", "x": "2", "c": "3", "v": "4", "b": "5",
        "n": "6", "m": "7",
    ]

    static func rows(layer: KBLayer, shift: Bool, swipe: Bool = true) -> [[KeySpec]] {
        switch layer {
        case .letters: return letterRows(shift: shift, swipe: swipe)
        case .numbers: return numberRows
        case .symbols: return symbolRows
        }
    }

    // MARK: - 字母层

    static func letterRows(shift: Bool, swipe: Bool = true) -> [[KeySpec]] {
        var out: [[KeySpec]] = []
        out.append(letterRow1.map {
            KeySpec("L\($0)", String($0).uppercased(), 1, .letter(String($0)),
                    popup: true, swipe: swipe ? letterSwipe[$0] : nil)
        })
        out.append(letterRow2.map {
            KeySpec("L\($0)", String($0).uppercased(), 1, .letter(String($0)),
                    popup: true, swipe: swipe ? letterSwipe[$0] : nil)
        })
        var r3: [KeySpec] = [KeySpec("shift", "⇧", 1.4, .shift,
                                     special: true, active: shift)]
        r3 += letterRow3.map {
            KeySpec("L\($0)", String($0).uppercased(), 1, .letter(String($0)),
                    popup: true, swipe: swipe ? letterSwipe[$0] : nil)
        }
        r3.append(KeySpec("backspace", "⌫", 1.4, .backspace, special: true))
        out.append(r3)
        out.append(bottomRow(leading: KeySpec("to123", "123", 1.5,
                                              .toLayer(.numbers), special: true)))
        return out
    }

    // MARK: - 数字层

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

    // MARK: - 符号层

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

    /// 数字/符号层的第三行：中文标点 + 退格
    private static func symbolRow3(leading: KeySpec) -> [KeySpec] {
        var r: [KeySpec] = [leading]
        for ch in ["，", "。", "？", "！", "、"] {
            r.append(KeySpec("P\(ch)", ch, 1, .text(ch), popup: true))
        }
        r.append(KeySpec("backspace", "⌫", 1.4, .backspace, special: true))
        return r
    }

    /// 各层共用的底行：层切换 + 地球 + 空格 + 换行（数字功能就靠 leading 那个 123/ABC）
    private static func bottomRow(leading: KeySpec) -> [KeySpec] {
        [
            leading,
            KeySpec("globe", "🌐", 1.2, .globe, special: true),
            KeySpec("space", "空格", 4.6, .space, special: true),
            KeySpec("ret", "换行", 1.7, .ret, special: true),
        ]
    }
}
