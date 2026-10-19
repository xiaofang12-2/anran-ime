// -*- coding: utf-8 -*-
/// 双拼支持：把「两键一音节」的编码解码回全拼喂给引擎。
///
/// 键位表由 tools/gen_shuangpin.py 执行 rime-ice 官方 schema 的 algebra 生成
/// （见 DoublePinyinTables.swift），零声母同时收录各方案官方标准码与 rime
/// algebra 产物，兼容搜狗/百度/QQ 与 rime 两拨用户的肌肉记忆。
///
/// 接入方式：键盘只管攒键，敲键/删键/上屏走后都过一遍 decodePrefix 拿全拼，
/// 引擎侧看到的始终是全拼 —— 模糊音、纠错、简拼、智能造词全部原样生效。
import Foundation

/// 双拼方案。rawValue 存进 IMESettings 随配置同步。
enum DoublePinyinScheme: String, CaseIterable {
    case off = "off"
    case flypy = "flypy"
    case mspy = "mspy"
    case sogou = "sogou"
    case nature = "nature"
    case ziguang = "ziguang"
    case abc = "abc"
    case jiajia = "jiajia"

    var displayName: String {
        switch self {
        case .off: return "全拼"
        case .flypy: return "小鹤双拼"
        case .mspy: return "微软双拼"
        case .sogou: return "搜狗双拼"
        case .nature: return "自然码"
        case .ziguang: return "紫光拼音"
        case .abc: return "智能ABC"
        case .jiajia: return "加加双拼"
        }
    }

    /// 未知 rawValue（老配置里存了别的串）时的兜底
    static func safe(_ raw: String) -> DoublePinyinScheme {
        DoublePinyinScheme(rawValue: raw) ?? .off
    }
}

enum DoublePinyin {

    /// 键串 → 全拼。要求键串长度为偶且每一对都能解；
    /// 任一对解不出返回 nil（调用方按原键透传，走简拼/英文路径）。
    static func decode(_ keys: String, scheme: DoublePinyinScheme) -> String? {
        guard scheme != .off, !keys.isEmpty, keys.count % 2 == 0 else { return nil }
        guard let table = DoublePinyinTables.table(scheme.rawValue) else { return nil }
        let chars = Array(keys)
        var out = ""
        var i = 0
        while i < chars.count {
            let code = String(chars[i]) + String(chars[i + 1])
            guard let syls = table[code], let first = syls.first else { return nil }
            out += first
            i += 2
        }
        return out
    }

    /// 键串 → 全拼 + 解出的键对数。尾键不足一对时解掉偶数前缀，
    /// 尾键由调用方留在 composing 里（双拼的正常中间态：候选跟着已解出的部分走）。
    static func decodePrefix(_ keys: String, scheme: DoublePinyinScheme)
        -> (full: String, pairs: Int)? {
        guard scheme != .off, !keys.isEmpty else { return nil }
        let even = keys.count % 2 == 0 ? keys : String(keys.dropLast())
        guard let full = decode(even, scheme: scheme) else { return nil }
        return (full, even.count / 2)
    }

    /// 全拼 → 双拼键串（上屏吃掉部分拼音后，剩下的拼音要编回键串接着拼）。
    /// 音节贪心最长匹配；任一音节没有编码返回 nil。
    static func encode(_ pinyin: String, scheme: DoublePinyinScheme) -> String? {
        guard scheme != .off, !pinyin.isEmpty else { return nil }
        guard let table = DoublePinyinTables.table(scheme.rawValue) else { return nil }
        var rev: [String: String] = [:]
        for (code, syls) in table {
            for s in syls where rev[s] == nil || code < rev[s]! {
                rev[s] = code
            }
        }
        var out = ""
        var i = pinyin.startIndex
        while i < pinyin.endIndex {
            var matched = false
            let maxLen = min(6, pinyin.distance(from: i, to: pinyin.endIndex))
            for len in stride(from: maxLen, through: 1, by: -1) {
                let end = pinyin.index(i, offsetBy: len)
                if let code = rev[String(pinyin[i..<end])] {
                    out += code
                    i = end
                    matched = true
                    break
                }
            }
            if !matched { return nil }
        }
        return out
    }
}
