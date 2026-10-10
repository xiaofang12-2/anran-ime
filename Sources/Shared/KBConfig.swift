import Foundation
import UIKit

/// 键盘外观/布局参数，用户在主程序「键盘布局」里自己调。
///
/// 主程序与键盘是两个沙盒，免费签名又用不了 App Groups，所以交接走剪贴板：
/// 主程序存一次就把整份配置塞进剪贴板，键盘一开就接过去（见 KBConfigStore）。
struct KBConfig: Codable, Equatable {
    /// 字母键高度
    var keyHeight: Double = 45
    /// 键与键的横向间距
    var keyGap: Double = 6
    /// 行与行的纵向间距
    var rowGap: Double = 6
    /// 键帽圆角
    var corner: Double = 6
    /// 字号缩放（1.0 为基准）
    var fontScale: Double = 1.0
    /// 键盘左右边距
    var sideInset: Double = 3
    /// 键盘底部留白
    var bottomInset: Double = 5
    /// 版本戳，主程序每存一次就刷新，键盘按它判新旧，不会拿旧的盖新的
    var rev: Int = 0

    static let fallback = KBConfig()
    static let pastePrefix = "ANRAN-KBCFG::"

    /// 取值范围，滑杆与兜底都用它，免得用户拖出个不能用的键盘
    static let ranges: [(label: String, lo: Double, hi: Double, unit: String)] = [
        ("按键高度", 34, 70, "pt"),
        ("按键间距", 2, 14, "pt"),
        ("行间距", 2, 14, "pt"),
        ("键帽圆角", 0, 16, "pt"),
        ("字号大小", 0.7, 1.5, "x"),
        ("左右边距", 0, 16, "pt"),
        ("底部留白", 0, 16, "pt"),
    ]

    var sanitized: KBConfig {
        var c = self
        c.keyHeight = KBConfig.clamp(c.keyHeight, 34, 70)
        c.keyGap = KBConfig.clamp(c.keyGap, 2, 14)
        c.rowGap = KBConfig.clamp(c.rowGap, 2, 14)
        c.corner = KBConfig.clamp(c.corner, 0, 16)
        c.fontScale = KBConfig.clamp(c.fontScale, 0.7, 1.5)
        c.sideInset = KBConfig.clamp(c.sideInset, 0, 16)
        c.bottomInset = KBConfig.clamp(c.bottomInset, 0, 16)
        return c
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

enum KBConfigStore {

    private static let key = "anran_kb_config"

    /// 键盘侧当前生效的配置
    static var current: KBConfig {
        guard let d = UserDefaults.standard.data(forKey: key),
              let c = try? JSONDecoder().decode(KBConfig.self, from: d) else {
            return KBConfig.fallback
        }
        return c.sanitized
    }

    static func saveLocal(_ c: KBConfig) {
        if let d = try? JSONEncoder().encode(c.sanitized) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    /// 主程序用：存本机 + 塞剪贴板，键盘一开自动接
    @discardableResult
    static func publish(_ c: KBConfig) -> Bool {
        var n = c.sanitized
        n.rev = Int(Date().timeIntervalSince1970)
        saveLocal(n)
        guard let d = try? JSONEncoder().encode(n),
              let s = String(data: d, encoding: .utf8) else { return false }
        UIPasteboard.general.string = KBConfig.pastePrefix + s
        return true
    }

    /// 键盘用：剪贴板里有更新的配置才接（按 rev 判新旧）
    @discardableResult
    static func pullFromPasteboard() -> Bool {
        guard let raw = UIPasteboard.general.string,
              raw.hasPrefix(KBConfig.pastePrefix) else { return false }
        let json = String(raw.dropFirst(KBConfig.pastePrefix.count))
        guard let d = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(KBConfig.self, from: d)
        else { return false }
        guard incoming.rev > current.rev else { return false }
        saveLocal(incoming)
        return true
    }
}
