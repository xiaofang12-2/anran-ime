import Foundation

/// 「特殊字体」——零宽字符加密。
///
/// 开启后往输出文本里插零宽字符（zero-width space / non-joiner / joiner /
/// BOM），这些字符**视觉上完全不可见**，所以发出去的内容看起来还是原文、
/// 不带任何花样字体；但它们打断了字符串连续匹配，平台的敏感词/风控按
/// 「原文」匹配就会落空。随机混用多种零宽字符，避免被统一 strip。
enum AntiDetect {

    /// 零宽字符池：零宽空格 / 零宽非连接符 / 零宽连接符。
    /// 刻意不含 U+FEFF（零宽无断空格）：它是 no-break 字符，插在行尾会把
    /// 后面的换行「粘」住，导致两句话糊成一行（分行丢失的元凶之一）。
    private static let zws: [Character] = ["\u{200B}", "\u{200C}", "\u{200D}"]

    /// 是否开启（读「输入设置 → 特殊字体」）
    static var enabled: Bool { IMESettingsStore.current.antiDetect }

    /// 整段加密：每个非空白字符后面跟一个随机零宽字符。
    /// 换行 / 空格不插（否则换行和分词被破坏）。单字、末尾都插 ——
    /// 保证「只要是我们输入法输出出去的内容」全带加密，任意子串都匹配不到。
    static func apply(_ text: String) -> String {
        guard enabled, !text.isEmpty else { return text }
        var out = ""
        for ch in text {
            out.append(ch)
            if !ch.isWhitespace {
                out.append(zws.randomElement()!)
            }
        }
        return out
    }

    /// 单字符加密（逐字上屏用）：非空白字符后面跟一个零宽字符。
    static func applyCh(_ ch: String) -> String {
        guard enabled, let c = ch.first, !c.isWhitespace else { return ch }
        return ch + String(zws.randomElement()!)
    }
}
