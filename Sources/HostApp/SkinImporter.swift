import UIKit

/// 百度输入法皮肤导入器：iOS 百度皮肤 .bdi 本质是 zip 包，里面有一堆
/// 配置 json 和图片资源。能读出什么就映射什么 —— 读出颜色字段就用，
/// 读不出颜色就从背景图取平均色生成一整套配色，背景图压缩后随身带着。
enum SkinImporter {

    enum SkinError: LocalizedError {
        case notZip, noResource
        var errorDescription: String? {
            switch self {
            case .notZip: return "文件解不开，可能是个加密皮肤 —— 先在百度输入法里换个免费皮肤再导"
            case .noResource: return "包里没认出皮肤资源，格式不支持"
            }
        }
    }

    /// 皮肤包 → 主题。扔错误给上层弹提示。
    static func importSkin(_ data: Data) throws -> KBTheme {
        guard let files = (try? MiniZip(data))?.unzipAll(), !files.isEmpty else {
            throw SkinError.notZip
        }

        var theme = KBTheme()
        theme.name = "百度皮肤"

        // 1) 扫 json 配置，抓颜色字段
        var foundColors = false
        for (name, d) in files where name.hasSuffix(".json") {
            guard let obj = try? JSONSerialization.jsonObject(with: d),
                  let dict = flatten(obj) else { continue }
            if applyColorFields(dict, to: &theme) { foundColors = true }
        }

        // 2) 找背景图：名字带 background/bg 的最大图；没有就所有图里最大的
        let images = files.filter { $0.key.hasSuffix(".png") || $0.key.hasSuffix(".jpg")
                                    || $0.key.hasSuffix(".jpeg") }
        guard !images.isEmpty else {
            if !foundColors { throw SkinError.noResource }
            return theme
        }
        let bgEntry = images.max { a, b in
            let wa = isBackgroundName(a.key) ? 1_000_000_000 : 0
            let wb = isBackgroundName(b.key) ? 1_000_000_000 : 0
            return wa + a.value.count < wb + b.value.count
        }
        guard let entry = bgEntry, let img = UIImage(data: entry.value) else {
            if !foundColors { throw SkinError.noResource }
            return theme
        }

        // 3) 压背景图：最长边 1080 的 JPEG，控制在 ~400KB 内塞进整包
        if let squeezed = compress(img, maxSide: 1080, quality: 0.72) {
            theme.bgImage = squeezed.base64EncodedString()
        }

        // 4) json 没给颜色 → 从图里取平均色生成整套配色
        if !foundColors {
            theme.applyFromAverageColor(averageColor(of: img))
        }
        return theme
    }

    // MARK: - 颜色字段映射

    /// 把嵌套 json 拍平成 "a.b.c" → value
    private static func flatten(_ obj: Any, prefix: String = "") -> [String: Any] {
        var out: [String: Any] = [:]
        if let dict = obj as? [String: Any] {
            for (k, v) in dict {
                let key = prefix.isEmpty ? k.lowercased() : prefix + "." + k.lowercased()
                out[key] = v
                if v is [String: Any] {
                    out.merge(flatten(v, prefix: key)) { _, n in n }
                }
            }
        }
        return out
    }

    /// 按常见字段名把颜色填进主题。返回是否至少抓到一个颜色。
    private static func applyColorFields(_ dict: [String: Any], to theme: inout KBTheme) -> Bool {
        var any = false
        // (匹配词组, 目标字段)。宽松 contains 匹配，先长后短，键的配色
        // 字段（key_bg*）排在整体背景后面兜底，避免互相抢。
        let map: [([String], WritableKeyPath<KBTheme, String>)] = [
            (["keyboardbg", "keyboard_bg", "background_color", "bgcolor"], \.bg),
            (["keybg_normal", "key_normal_color", "key_bg", "keybg", "key_color", "keycolor"], \.key),
            (["keybg_pressed", "key_pressed", "pressed", "highlight"], \.keyPressed),
            (["funckey", "func_key", "special", "toolbar"], \.special),
            (["fontcolor", "font_color", "textcolor", "text_color", "font"], \.text),
        ]
        // 精确扫描：全字段排序后按最长匹配分派，避免 "font_color" 被 "font" 抢走
        let keys = dict.keys.sorted { $0.count > $1.count }
        var taken = Set<String>()
        for (words, path) in map {
            for k in keys where !taken.contains(k) {
                let hit = words.contains { w in
                    k == w || k.hasSuffix("." + w) || k.contains(w)
                }
                if hit, let hex = colorString(dict[k]) {
                    theme[keyPath: path] = hex
                    taken.insert(k)
                    any = true
                    break
                }
            }
        }
        return any
    }

    /// 颜色值 → "#RRGGBB" 形式的规范串。支持 "#RRGGBB" / "#AARRGGBB" / "r,g,b[,a]"
    private static func colorString(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") || t.hasPrefix("0x") {
            let hex = t.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "#", with: "")
            guard hex.count == 6 || hex.count == 8, UInt32(hex, radix: 16) != nil else { return nil }
            if hex.count == 8 {
                // AARRGGBB → 扔掉 alpha 保留 RGB（主题另有 bar 字段管透明）
                return "#" + String(hex.dropFirst(2))
            }
            return "#" + hex
        }
        // "255,255,255,255" 形式
        let parts = t.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count >= 3, parts.prefix(3).allSatisfy({ $0 >= 0 && $0 <= 255 }) {
            return String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2])
        }
        return nil
    }

    private static func isBackgroundName(_ name: String) -> Bool {
        let l = name.lowercased()
        return l.contains("background") || l.contains("bg_") || l.contains("_bg")
            || l.hasSuffix("bg.png") || l.contains("wallpaper")
    }

    // MARK: - 图片处理

    /// 压到最长边 maxSide 的 JPEG，超过 450KB 再降一档质量
    private static func compress(_ img: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let scale = min(1, maxSide / max(img.size.width, img.size.height))
        let target = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(target, false, 1)
        img.draw(in: CGRect(origin: .zero, size: target))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        guard let out else { return nil }
        var q = quality
        var d = out.jpegData(compressionQuality: q)
        while d?.count ?? 0 > 450_000, q > 0.35 {
            q -= 0.12
            d = out.jpegData(compressionQuality: q)
        }
        return d
    }

    /// 采样求平均色（抽 4000 个点，够准了）
    private static func averageColor(of img: UIImage) -> UIColor {
        guard let cg = img.cgImage else { return .white }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return .white }
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return .white }
        let px = buf.bindMemory(to: UInt8.self).capacity / 4
        let step = max(1, px / 4000)
        var r = 0, g = 0, b = 0, n = 0
        var i = 0
        while i < px {
            r += Int(buf.load(fromByteOffset: i * 4, as: UInt8.self))
            g += Int(buf.load(fromByteOffset: i * 4 + 1, as: UInt8.self))
            b += Int(buf.load(fromByteOffset: i * 4 + 2, as: UInt8.self))
            n += 1
            i += step
        }
        return UIColor(red: CGFloat(r) / CGFloat(n) / 255,
                       green: CGFloat(g) / CGFloat(n) / 255,
                       blue: CGFloat(b) / CGFloat(n) / 255, alpha: 1)
    }
}

extension KBTheme {

    /// 从背景图平均色生成整套配色：亮图配白键黑字，暗图配深键白字
    mutating func applyFromAverageColor(_ c: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let dark = lum < 0.45
        if dark {
            bg = String(format: "#%02X%02X%02X", Int(r * 110), Int(g * 110), Int(b * 110))
            key = String(format: "#%02X%02X%02X", 62, 64, 72)
            keyPressed = String(format: "#%02X%02X%02X", 80, 82, 92)
            special = String(format: "#%02X%02X%02X", 44, 45, 52)
            specialPressed = String(format: "#%02X%02X%02X", 60, 61, 70)
            text = "#F2F2F5"
            specialText = "#E8E8EE"
            bar = "#CC1A1B20"
            candidateText = "#F2F2F5"
            accent = "#5B9BFF"
        } else {
            bg = String(format: "#%02X%02X%02X", min(255, Int(r * 255) + 28),
                        min(255, Int(g * 255) + 28), min(255, Int(b * 255) + 28))
            text = "#111111"
            specialText = "#111111"
        }
    }
}
