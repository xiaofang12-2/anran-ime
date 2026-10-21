import SwiftUI

/// 键盘层：字母 / 数字 / 符号，三层靠布局里的「123」「ABC」「#+=」键互切
enum KBLayer {
    case letters, numbers, symbols
}

/// 顶部功能栏点开的浮层面板（对标百度：点图标在键盘上方冒出一块）
enum KBPanel {
    case none
    case clipboard
    case thought
    case brush
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
    /// SF Symbol 名（shift / 退格这种画图标的键）。有它画图标，没有才画 label
    let symbol: String?
    /// 单键高度覆盖（pt）。nil = 跟整行一样高（布局编辑器里给单键调高矮用）
    let height: CGFloat?

    init(_ id: String, _ label: String, _ weight: CGFloat,
         _ action: KeyAction, special: Bool = false,
         popup: Bool = false, active: Bool = false,
         swipe: String? = nil, symbol: String? = nil, height: CGFloat? = nil) {
        self.id = id
        self.label = label
        self.weight = weight
        self.action = action
        self.special = special
        self.popup = popup
        self.active = active
        self.swipe = swipe
        self.symbol = symbol
        self.height = height
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

    /// 当前主题与主题色（配置从主程序整包接过来后跟着 cfg 一起换）
    static var theme: KBTheme { cfg.activeTheme }

    static var themeKeyColor: Color { Color(hex: theme.key) }
    static var themeKeyPressedColor: Color { Color(hex: theme.keyPressed) }
    static var themeSpecialColor: Color { Color(hex: theme.special) }
    static var themeSpecialPressedColor: Color { Color(hex: theme.specialPressed) }
    static var themeTextColor: Color { Color(hex: theme.text) }
    static var themeSpecialTextColor: Color { Color(hex: theme.specialText) }
    static var themeBgColor: Color { Color(hex: theme.bg) }
    static var themeBarColor: Color { Color(hex: theme.bar) }
    static var themeCandidateTextColor: Color { Color(hex: theme.candidateText) }
    static var themeAccentColor: Color { Color(hex: theme.accent) }

    /// 皮肤背景图（主程序导入皮肤后随整包带过来）
    ///
    /// **必须缓存**：解码后的 UIImage 位图是「脏内存」，全额计入键盘扩展的
    /// jetsam 红线。原来写法是计算属性，每次 body 重渲染（每敲一个字母、每次
    /// 候选刷新）都重新 base64 解码 + 重解出一张几 MB 的位图 —— 打字时快速
    /// 连发会让多张位图同时存在，内存瞬间顶爆 → iOS 静默杀扩展 → 表现就是
    /// 「点一下字母输入法就跳走」。现在按 base64 串做 memoize：同皮肤只解一次，
    /// 切皮肤时自动失效重解；内存告急时 `releaseBgImage()` 主动放手。
    private static var _bgImageCache: (key: String, image: UIImage?)?
    static var themeBgImage: UIImage? {
        guard let b64 = theme.bgImage else {
            _bgImageCache = nil
            return nil
        }
        if let c = _bgImageCache, c.key == b64 { return c.image }
        let img = Data(base64Encoded: b64).flatMap { UIImage(data: $0) }
        _bgImageCache = (b64, img)
        return img
    }

    /// 内存告急（didReceiveMemoryWarning）时主动放手皮肤位图，避免被 jetsam
    static func releaseBgImage() { _bgImageCache = nil }

    /// 顶栏：LOGO + 候选词 + 功能图标 一行搞定（学百度，功能栏不再单独占一条）
    static let barHeight: CGFloat = 45
    /// 拼音输入行（学百度：已输入的字母单独一行，在图标上方，不跟候选挤在一起）
    static let pinyinRowHeight: CGFloat = 24
    /// 剪贴板面板高度
    static let panelHeight: CGFloat = 38
    /// 思想库输入框面板实际高度（输入框34 + 间距6 + 预览条20 + 上下边距16）
    static let thoughtPanelHeight: CGFloat = 76
    /// 展开候选栏高度（4行 x 8个 = 32个候选：上下边距16 + 行高32x4 + 行距6x3）
    static let candidatePanelHeight: CGFloat = 162
    static let topInset: CGFloat = 6

    /// 字母/数字/符号三层都是 4 行
    static let rows = 4

    /// extra = 展开的浮层面板额外占的高度（思想库/剪贴板）
    /// 顶层元素：顶栏 + 键区 rows 行，行间 rowGap 共 rows 个
    static func totalHeight(rows: Int, extra: CGFloat = 0,
                            composingRow: Bool = false) -> CGFloat {
        topInset + bottomInset
            + barHeight
            + (composingRow ? pinyinRowHeight : 0)
            + keyHeight * CGFloat(rows)
            + rowGap * CGFloat(max(rows, 1))
            + extra
    }
}

enum KeyboardLayout {

    /// 基准行键数（10 键满行）。键宽按它算死，少键的行整体居中 ——
    /// 这样第二行「asdfghjkl」会像 iOS 那样左右各缩进半个键，
    /// 第三行 shift/退格 加宽后字母键宽也不会被挤窄。
    static let canonicalKeys = 10

    /// 侧键（shift / 退格 / 123）相对字母键的宽度，对标参考图 138 : 102
    static let sideWeight: CGFloat = 1.35
    /// 底行两侧键（123 / 回车）宽度，对标参考图 282 : 102
    static let bottomSideWeight: CGFloat = 2.76
    /// 空格键宽度，对标参考图 582 : 102
    static let spaceWeight: CGFloat = 5.71

    private static let letterRow1 = Array("qwertyuiop")
    private static let letterRow2 = Array("asdfghjkl")
    private static let letterRow3 = Array("zxcvbnm")

    /// 字母键上滑 = 选候选拦对应位置的候选（q~o 对标候选拦第 1~9 个；
    /// 没有候选时上滑没效果 —— 见 KeyboardRootView.swipe）
    private static let letterSwipe: [Character: String] = [
        "q": "1", "w": "2", "e": "3", "r": "4", "t": "5",
        "y": "6", "u": "7", "i": "8", "o": "9",
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
        out.append(letterRow1.map { letterKey($0, shift: shift, swipe: swipe) })
        out.append(letterRow2.map { letterKey($0, shift: shift, swipe: swipe) })
        var r3: [KeySpec] = [KeySpec("shift", "⇧", sideWeight, .shift,
                                     special: true, active: shift,
                                     symbol: shift ? "shift.fill" : "shift")]
        r3 += letterRow3.map { letterKey($0, shift: shift, swipe: swipe) }
        r3.append(KeySpec("backspace", "⌫", sideWeight, .backspace,
                          special: true, symbol: "delete.left"))
        out.append(r3)
        out.append(bottomRow(leading: KeySpec("to123", "123", bottomSideWeight,
                                              .toLayer(.numbers), special: true)))
        return out
    }

    /// 字母键：默认小写（对标参考图），点亮 shift 才显示大写。
    /// action 一律给小写字母 —— 中文拼音本来就是小写，shift 只在
    /// 「拼音串为空 + 手按了 shift」时才把字母当英文大写上屏。
    private static func letterKey(_ ch: Character, shift: Bool, swipe: Bool) -> KeySpec {
        let lower = String(ch)
        return KeySpec("L\(ch)", shift ? lower.uppercased() : lower, 1,
                       .letter(lower), popup: true,
                       swipe: swipe ? letterSwipe[ch] : nil)
    }

    // MARK: - 数字层

    static var numberRows: [[KeySpec]] {
        let r1 = Array("1234567890")
        let r2 = Array("-/:;()¥&@\"")
        return [
            r1.map { KeySpec("N\($0)", String($0), 1, .text(String($0)), popup: true) },
            r2.map { KeySpec("N\($0)", String($0), 1, .text(String($0)), popup: true) },
            symbolRow3(leading: KeySpec("toSym", "#+=", sideWeight,
                                        .toLayer(.symbols), special: true)),
            bottomRow(leading: KeySpec("toABC", "ABC", bottomSideWeight,
                                       .toLayer(.letters), special: true)),
        ]
    }

    // MARK: - 符号层

    static var symbolRows: [[KeySpec]] {
        let r1 = Array("[]{}#%^*+=")
        let r2 = Array("_\\|~<>€£¥•")
        return [
            r1.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            r2.map { KeySpec("S\($0)", String($0), 1, .text(String($0)), popup: true) },
            symbolRow3(leading: KeySpec("to123", "123", sideWeight,
                                        .toLayer(.numbers), special: true)),
            bottomRow(leading: KeySpec("toABC", "ABC", bottomSideWeight,
                                       .toLayer(.letters), special: true)),
        ]
    }

    /// 数字/符号层的第三行：中文标点 + 退格
    private static func symbolRow3(leading: KeySpec) -> [KeySpec] {
        var r: [KeySpec] = [leading]
        for ch in ["，", "。", "？", "！", "、"] {
            r.append(KeySpec("P\(ch)", ch, 1, .text(ch), popup: true))
        }
        r.append(KeySpec("backspace", "⌫", sideWeight, .backspace,
                         special: true, symbol: "delete.left"))
        return r
    }

    /// 各层共用的底行：层切换 + 空格 + 回车（对标参考图「123 / 空格 / 发送」三键）。
    /// 回车键文案由 KeyboardRootView 按宿主 App 的 returnKeyType 覆盖。
    private static func bottomRow(leading: KeySpec) -> [KeySpec] {
        [
            leading,
            KeySpec("space", "空格", spaceWeight, .space, special: true),
            KeySpec("ret", "换行", bottomSideWeight, .ret, special: true),
        ]
    }
}