import SwiftUI

/// 键盘层
enum KBLayer {
    case letters, numbers, symbols
}

/// 一个键的动作
enum KeyAction {
    case letter(String)      // 26 键字母（吃 shift 影响）
    case t9(String)          // 9 键数字（往拼音串里加数字）
    case text(String)        // 直接上屏的符号/数字
    case shift
    case backspace
    case space
    case ret
    case globe
    case toLayer(KBLayer)
    case modeToggle          // 26 键 <-> 9 键
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
    /// 9 键上那个数字键副标（如 2 上的 abc）
    let sub: String?

    init(_ id: String, _ label: String, _ weight: CGFloat,
         _ action: KeyAction, special: Bool = false,
         popup: Bool = false, active: Bool = false,
         swipe: String? = nil, sub: String? = nil) {
        self.id = id
        self.label = label
        self.weight = weight
        self.action = action
        self.special = special
        self.popup = popup
        self.active = active
        self.swipe = swipe
        self.sub = sub
    }
}

/// 尺寸常量，对标 iOS 原生键盘（百度输入法同一套骨架）
/// 键高比原生略抬一点，手指落点更松，连打不易误触
enum KBMetrics {
    static let rowGap: CGFloat = 7
    static let keyGap: CGFloat = 6
    static let sideInset: CGFloat = 3
    static let keyHeight: CGFloat = 47
    static let barHeight: CGFloat = 46
    static let topInset: CGFloat = 7
    static let bottomInset: CGFloat = 6
    static let corner: CGFloat = 6

    /// 26 键 4 行、9 键 5 行，高度按行数算
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

    /// 26 键：字母键上滑出对应数字
    private static let letterSwipe: [Character: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9", "p": "0",
        "a": "1", "s": "2", "d": "3", "f": "4", "g": "5",
        "h": "6", "j": "7", "k": "8", "l": "9",
        "z": "1", "x": "2", "c": "3", "v": "4", "b": "5",
        "n": "6", "m": "7",
    ]

    static func rows(layer: KBLayer, shift: Bool, mode: KBMode) -> [[KeySpec]] {
        switch layer {
        case .letters:
            return mode == .t9 ? t9LetterRows : letterRows(shift: shift)
        case .numbers:
            return mode == .t9 ? t9NumberRows : numberRows
        case .symbols:
            return mode == .t9 ? t9SymbolRows : symbolRows
        }
    }

    static func rowCount(mode: KBMode) -> Int {
        mode == .t9 ? 5 : 4
    }

    // MARK: - 26 键

    static func letterRows(shift: Bool) -> [[KeySpec]] {
        var out: [[KeySpec]] = []
        out.append(letterRow1.map {
            KeySpec("L\($0)", String($0).uppercased(), 1, .letter(String($0)),
                    popup: true, swipe: letterSwipe[$0])
        })
        out.append(letterRow2.map {
            KeySpec("L\($0)", String($0).uppercased(), 1, .letter(String($0)),
                    popup: true, swipe: letterSwipe[$0])
        })
        var r3: [KeySpec] = [KeySpec("shift", "⇧", 1.4, .shift,
                                     special: true, active: shift)]
        r3 += letterRow3.map {
            KeySpec("L\($0)", String($0).uppercased(), 1, .letter(String($0)),
                    popup: true, swipe: letterSwipe[$0])
        }
        r3.append(KeySpec("backspace", "⌫", 1.4, .backspace, special: true))
        out.append(r3)
        out.append([
            KeySpec("to123", "123", 1.5, .toLayer(.numbers), special: true),
            KeySpec("comma", "，", 1.0, .text("，"), special: true),
            KeySpec("globe", "🌐", 1.2, .globe, special: true),
            KeySpec("space", "空格", 4.6, .space, special: true),
            KeySpec("period", "。", 1.0, .text("。"), special: true),
            KeySpec("ret", "换行", 1.7, .ret, special: true),
        ])
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

    /// 数字/符号层的第三行：中文标点 + 退格
    private static func symbolRow3(leading: KeySpec) -> [KeySpec] {
        var r: [KeySpec] = [leading]
        for ch in ["，", "。", "？", "！", "、"] {
            r.append(KeySpec("P\(ch)", ch, 1, .text(ch), popup: true))
        }
        r.append(KeySpec("backspace", "⌫", 1.4, .backspace, special: true))
        return r
    }

    /// 26 键第四行：层切换 + 地球 + 空格 + 换行 + 形态切换
    private static func bottomRow(leading: KeySpec) -> [KeySpec] {
        [
            leading,
            KeySpec("globe", "🌐", 1.2, .globe, special: true),
            KeySpec("space", "空格", 4.6, .space, special: true),
            KeySpec("ret", "换行", 1.7, .ret, special: true),
            KeySpec("mode", "9键", 1.5, .modeToggle, special: true),
        ]
    }

    // MARK: - 9 键

    private static let t9Groups: [(String, String)] = [
        ("1", ""), ("2", "abc"), ("3", "def"),
        ("4", "ghi"), ("5", "jkl"), ("6", "mno"),
        ("7", "pqrs"), ("8", "tuv"), ("9", "wxyz"),
    ]

    private static func t9Key(_ d: String, _ sub: String) -> KeySpec {
        KeySpec("T\(d)", d, 1, .t9(d), popup: true, sub: sub.isEmpty ? nil : sub)
    }

    static var t9LetterRows: [[KeySpec]] {
        var out: [[KeySpec]] = []
        out.append(t9Groups[0...2].map { t9Key($0.0, $0.1) })
        out.append(t9Groups[3...5].map { t9Key($0.0, $0.1) })
        out.append(t9Groups[6...8].map { t9Key($0.0, $0.1) })
        out.append([
            KeySpec("to123", "123", 1.5, .toLayer(.numbers), special: true),
            t9Key("0", ""),
            KeySpec("backspace", "⌫", 1.5, .backspace, special: true),
        ])
        out.append([
            KeySpec("globe", "🌐", 1.2, .globe, special: true),
            KeySpec("space", "空格", 4.6, .space, special: true),
            KeySpec("ret", "换行", 1.7, .ret, special: true),
            KeySpec("mode", "26键", 1.5, .modeToggle, special: true),
        ])
        return out
    }

    static var t9NumberRows: [[KeySpec]] {
        var out: [[KeySpec]] = []
        out.append(t9Groups[0...2].map { t9Key($0.0, "") })
        out.append(t9Groups[3...5].map { t9Key($0.0, "") })
        out.append(t9Groups[6...8].map { t9Key($0.0, "") })
        out.append(Array("-/:;()").map {
            KeySpec("N\($0)", String($0), 1, .text(String($0)), popup: true)
        })
        out.append([
            KeySpec("toABC", "ABC", 1.5, .toLayer(.letters), special: true),
            t9Key("0", ""),
            KeySpec("backspace", "⌫", 1.5, .backspace, special: true),
            KeySpec("space", "空格", 3.0, .space, special: true),
            KeySpec("ret", "换行", 1.5, .ret, special: true),
        ])
        return out
    }

    static var t9SymbolRows: [[KeySpec]] {
        let r1 = Array("[]{}#%^")
        let r2 = Array("*+=_\\|~")
        let r3 = Array("<>€£¥•")
        let r4 = Array("，。？！、；")
        return [
            r1.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            r2.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            r3.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            r4.map { KeySpec("P\($0)", String($0), 1, .text(String($0)), popup: true) },
            [
                KeySpec("to123", "123", 1.4, .toLayer(.numbers), special: true),
                KeySpec("toABC", "ABC", 1.4, .toLayer(.letters), special: true),
                KeySpec("backspace", "⌫", 1.4, .backspace, special: true),
                KeySpec("space", "空格", 3.0, .space, special: true),
                KeySpec("ret", "换行", 1.5, .ret, special: true),
            ],
        ]
    }
}