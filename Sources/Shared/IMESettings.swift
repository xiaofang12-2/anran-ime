import Foundation
import UIKit

/// 输入法行为设置（对标百度「输入设置 / 键盘设置」）。
///
/// 与「键盘布局」「自定义短语」一样，主程序改完走剪贴板交给键盘
/// （免费签名用不了 App Groups，见 ConfigSync）。
struct IMESettings: Codable, Equatable {
    /// 模糊音：zh/z、ch/c、sh/s、ang/an、n/l 等互相容错
    var fuzzyPinyin = true
    /// 简拼 / 混拼：nh → 你好、zme → 怎么
    var abbrevInput = true
    /// 智能纠错：按错相邻键也能出词（nihap → 你好）
    var smartCorrect = true
    /// 字母键上滑出数字
    var swipeNumber = true
    /// 句首自动大写（英文）
    var autoCapitalize = true
    /// 按键音效
    var keySound = true
    /// 按键震动（默认关，本产品用扣字音效替代）
    var vibration = false
    /// 候选数量上限
    var candidateCount = 40
    /// 「清空打字学习记录」的一次性令牌：主程序点一次就刷新时间戳，
    /// 键盘见到比本地新就清一次（键盘沙盒里读不到主程序的存储，只能这么传令）
    var clearLearnToken = 0
    /// 版本戳
    var rev: Int = 0

    static let fallback = IMESettings()
    static let pastePrefix = "ANRAN-IMSET::"

    static let candidateRange: ClosedRange<Int> = 10...60

    var sanitized: IMESettings {
        var s = self
        s.candidateCount = min(max(s.candidateCount, IMESettings.candidateRange.lowerBound),
                               IMESettings.candidateRange.upperBound)
        return s
    }
}

enum IMESettingsStore {

    private static let key = "anran_ime_settings"

    /// 键盘热路径（每次敲键）要读，缓存在内存里，别每次解 JSON
    private(set) static var current: IMESettings = load()

    static func load() -> IMESettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(IMESettings.self, from: d) else {
            return IMESettings.fallback
        }
        return s.sanitized
    }

    static func saveLocal(_ s: IMESettings) {
        let n = s.sanitized
        current = n
        if let d = try? JSONEncoder().encode(n) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
