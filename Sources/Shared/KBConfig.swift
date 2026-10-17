import Foundation
import SwiftUI

/// 单个按键的自定义覆盖：宽度 + 行内位置 + 高度 + 上滑符号 + 删除。
/// id 用 KeySpec 的 id（如 "Lq"、"backspace"、"space"）。
struct KeyOverride: Codable, Equatable {
    /// 宽度权重覆盖（nil = 跟默认一样）
    var weight: Double?
    /// 行内位置偏移：负 = 左移几格，正 = 右移几格（0 = 原位）。
    /// 旧字段，新的绝对定位用 pos；老数据解码后照常生效。
    var shift: Int = 0
    /// 行内绝对位置（从 1 开始）。nil = 不动
    var pos: Int?
    /// 单键高度（pt）。nil = 跟整行一样
    var height: Double?
    /// 上滑打出的符号。nil = 跟默认一样
    var swipe: String?
    /// 删除该键
    var deleted: Bool = false

    /// 一个覆盖是不是等于"没改过"（省得存一堆空覆盖）
    func isEmpty(vs baseWeight: Double) -> Bool {
        (weight == nil || abs(weight! - baseWeight) < 0.01)
            && shift == 0 && pos == nil && height == nil
            && (swipe == nil || swipe!.isEmpty) && !deleted
    }
}

/// 用户自己加的按键（布局编辑器「添加按键」造出来）
struct CustomKey: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    /// 键帽文字（也是点按直接上屏的内容）
    var label: String = ""
    /// 放在哪一行：0 = qwertyuiop / 1 = asdfghjkl / 2 = zxcvbnm
    var row: Int = 2
    /// 上滑打出的符号
    var swipe: String?
    /// 宽度权重（1 = 标准键宽）
    var weight: Double = 1
}

/// 主题配色：颜色一律存 hex（含 #AARRGGBB 形式），跨剪贴板整包交接。
/// bgImage 是压缩后的 base64 JPEG（皮肤背景图），键盘侧解出来铺底。
struct KBTheme: Codable, Equatable {
    var name: String = "经典白"
    /// 键盘整体背景
    var bg: String = "#D2D4DA"
    /// 普通键帽
    var key: String = "#FFFFFF"
    var keyPressed: String = "#B9BCC3"
    /// 功能键（shift/空格/退格/123）
    var special: String = "#ACAFB8"
    var specialPressed: String = "#8F939D"
    /// 键帽文字
    var text: String = "#111111"
    var specialText: String = "#111111"
    /// 候选栏/功能栏底色（可带透明度，#AARRGGBB）
    var bar: String = "#A6FFFFFF"
    /// 候选栏文字（首个候选重点色）
    var candidateText: String = "#111111"
    /// 候选栏高亮（首选/命中图标色）
    var accent: String = "#3380F2"
    /// 皮肤背景图（base64 JPEG，最长边 ≤1080）
    var bgImage: String?

    static let classic = KBTheme()

    /// 内置预设：不用导皮肤也有得挑
    static let presets: [KBTheme] = [
        classic,
        KBTheme(name: "暗夜黑", bg: "#1C1D22", key: "#3A3C44", keyPressed: "#4A4C55",
                special: "#2A2B31", specialPressed: "#3A3B42",
                text: "#F2F2F5", specialText: "#E8E8EE",
                bar: "#CC26272D", candidateText: "#F2F2F5", accent: "#5B9BFF"),
        KBTheme(name: "樱花粉", bg: "#FBE8EE", key: "#FFFFFF", keyPressed: "#F7CFDD",
                special: "#F3BFD2", specialPressed: "#EBA8C2",
                text: "#5A2A3C", specialText: "#5A2A3C",
                bar: "#B3FFFFFF", candidateText: "#5A2A3C", accent: "#E85D92"),
        KBTheme(name: "深海蓝", bg: "#E3ECF7", key: "#FFFFFF", keyPressed: "#C2D6EF",
                special: "#AFC8E8", specialPressed: "#93B4DD",
                text: "#16324F", specialText: "#16324F",
                bar: "#B3FFFFFF", candidateText: "#16324F", accent: "#2E6FC2"),
        KBTheme(name: "护眼绿", bg: "#E4EFE3", key: "#FFFFFF", keyPressed: "#C6DEC5",
                special: "#B2CFAF", specialPressed: "#96BB93",
                text: "#1E3A1D", specialText: "#1E3A1D",
                bar: "#B3FFFFFF", candidateText: "#1E3A1D", accent: "#3E8A3B"),
    ]
}

/// 键盘外观/布局参数，用户在主程序「键盘布局」里自己调。
///
/// 主程序与键盘是两个沙盒，免费签名又用不了 App Groups，所以交接走剪贴板：
/// 主程序存一次就把整份配置塞进剪贴板，键盘一开就接过去（见 ConfigSync）。
struct KBConfig: Codable, Equatable {
    /// 字母键高度
    var keyHeight: Double = 45
    /// 键与键的横向间距
    var keyGap: Double = 6
    /// 行与行的纵向间距（对标 iOS：纵向明显比横向松）
    var rowGap: Double = 10
    /// 键帽圆角
    var corner: Double = 4
    /// 字号缩放（1.0 为基准）
    var fontScale: Double = 1.0
    /// 键盘左右边距
    var sideInset: Double = 4
    /// 键盘底部留白
    var bottomInset: Double = 7
    /// 主题配色（皮肤）
    var theme: KBTheme?
    /// 按键级覆盖：id → 宽度/位置/高度/上滑/删除（「键盘布局」编辑器写进来）
    var keyOverrides: [String: KeyOverride]?
    /// 用户自己新增的按键
    var customKeys: [CustomKey]?
    /// 版本戳，主程序每存一次就刷新，键盘按它判新旧，不会拿旧的盖新的
    var rev: Int = 0

    static let fallback = KBConfig()

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

    /// 当前生效主题（没设过就是经典白）
    var activeTheme: KBTheme { theme ?? .classic }
}

// MARK: - 键位覆盖应用

enum KeyOverrideApplier {

    /// 把用户对单个键的调整套到键位表上：
    /// 删除 → 行内移位（旧字段）→ 绝对位置 → 宽度/高度/上滑。
    static func apply(_ rows: [[KeySpec]], overrides: [String: KeyOverride]?) -> [[KeySpec]] {
        guard let ov = overrides, !ov.isEmpty else { return rows }
        return rows.map { row in
            var r = row.filter { !(ov[$0.id]?.deleted ?? false) }
            // 旧式移位：把键跟目标位置的键交换
            for (origIdx, key) in row.enumerated() {
                guard let o = ov[key.id], o.shift != 0 else { continue }
                guard let cur = r.firstIndex(where: { $0.id == key.id }) else { continue }
                let target = min(max(origIdx + o.shift, 0), r.count - 1)
                if target != cur { r.swapAt(cur, target) }
            }
            // 绝对位置：把键挪到第 pos 格（1 起算，越界贴到行尾）
            for key in row {
                guard let o = ov[key.id], let p = o.pos, p >= 1 else { continue }
                guard let cur = r.firstIndex(where: { $0.id == key.id }) else { continue }
                let target = min(p - 1, r.count - 1)
                if target != cur {
                    r.remove(at: cur)
                    r.insert(key, at: min(target, r.count))
                }
            }
            // 宽度/高度/上滑覆盖：重建 KeySpec
            return r.map { k in
                guard let o = ov[k.id] else { return k }
                let w = (o.weight.flatMap { $0 > 0 ? $0 : nil }) ?? Double(k.weight)
                let h = o.height.flatMap { $0 > 0 ? CGFloat($0) : nil }
                let s = (o.swipe?.isEmpty == false) ? o.swipe : k.swipe
                if w == Double(k.weight) && h == nil && s == k.swipe { return k }
                return KeySpec(k.id, k.label, CGFloat(w), k.action,
                               special: k.special, popup: k.popup,
                               active: k.active, swipe: s, symbol: k.symbol,
                               height: h)
            }
        }
    }

    /// 把用户新增的按键挂到对应行尾（键盘和编辑器预览共用）
    static func addCustom(_ rows: [[KeySpec]], keys: [CustomKey]?) -> [[KeySpec]] {
        guard let custom = keys, !custom.isEmpty else { return rows }
        var r = rows
        for k in custom {
            let rowIdx = min(max(k.row, 0), r.count - 1)
            let spec = KeySpec(k.id, k.label, CGFloat(k.weight), .text(k.label),
                               swipe: (k.swipe?.isEmpty == false) ? k.swipe : nil)
            r[rowIdx].append(spec)
        }
        return r
    }
}

// MARK: - hex 颜色

extension Color {
    /// 解析 "#RRGGBB" / "#AARRGGBB" / "RRGGBB"；解析失败给个中灰
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var a: Double = 1, r: Double = 0.6, g: Double = 0.6, b: Double = 0.6
        switch s.count {
        case 6:
            if let v = UInt32(s, radix: 16) {
                r = Double((v >> 16) & 0xFF) / 255
                g = Double((v >> 8) & 0xFF) / 255
                b = Double(v & 0xFF) / 255
            }
        case 8:
            if let v = UInt32(s, radix: 16) {
                a = Double((v >> 24) & 0xFF) / 255
                r = Double((v >> 16) & 0xFF) / 255
                g = Double((v >> 8) & 0xFF) / 255
                b = Double(v & 0xFF) / 255
            }
        default:
            break
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
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
}
