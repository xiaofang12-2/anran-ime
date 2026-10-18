import Foundation

/// 输入法行为设置（对标百度「输入设置 / 键盘设置」）。
///
/// 与「键盘布局」「自定义短语」一样，主程序改完整包推服务器、键盘自动拉
/// （见 ConfigSync）。
struct IMESettings: Codable, Equatable {
    /// 模糊音：zh/z、ch/c、sh/s、ang/an、n/l 等互相容错
    var fuzzyPinyin = true
    /// 简拼 / 混拼：nh → 你好、zme → 怎么
    var abbrevInput = true
    /// 智能纠错：按错相邻键也能出词（nihap → 你好）
    var smartCorrect = true
    /// 句首自动大写（英文）
    var autoCapitalize = true
    /// 按键音效
    var keySound = true
    /// 按键震动（默认关，本产品用扣字音效替代）
    var vibration = false
    /// 候选数量上限
    var candidateCount = 40
    /// 思想库逐字上屏间隔（毫秒）：0 = 瞬间连上（最快），300 = 最慢
    var outputSpeed = 20
    /// 「清空打字学习记录」的一次性令牌：主程序点一次就刷新时间戳，
    /// 键盘见到比本地新就清一次（键盘沙盒里读不到主程序的存储，只能这么传令）
    var clearLearnToken = 0
    /// 尾巴：开启后思想库发出去的每句尾部带尾巴符号
    var tailEnabled = false
    /// 尾巴符号（单个，如 。 或 .）
    var tailSymbol = ""
    /// 版本戳
    var rev: Int = 0

    static let fallback = IMESettings()

    static let candidateRange: ClosedRange<Int> = 10...60
    static let outputSpeedRange: ClosedRange<Int> = 0...300

    private enum CodingKeys: String, CodingKey {
        case fuzzyPinyin, abbrevInput, smartCorrect, autoCapitalize
        case keySound, vibration, candidateCount, outputSpeed
        case clearLearnToken, tailEnabled, tailSymbol, rev
    }

    /// 老版本存的 JSON 缺新字段也能解（缺的补默认值），设置不会被整体重置
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fuzzyPinyin     = try c.decodeIfPresent(Bool.self, forKey: .fuzzyPinyin) ?? true
        abbrevInput     = try c.decodeIfPresent(Bool.self, forKey: .abbrevInput) ?? true
        smartCorrect    = try c.decodeIfPresent(Bool.self, forKey: .smartCorrect) ?? true
        autoCapitalize  = try c.decodeIfPresent(Bool.self, forKey: .autoCapitalize) ?? true
        keySound        = try c.decodeIfPresent(Bool.self, forKey: .keySound) ?? true
        vibration       = try c.decodeIfPresent(Bool.self, forKey: .vibration) ?? false
        candidateCount  = try c.decodeIfPresent(Int.self, forKey: .candidateCount) ?? 40
        outputSpeed     = try c.decodeIfPresent(Int.self, forKey: .outputSpeed) ?? 20
        clearLearnToken = try c.decodeIfPresent(Int.self, forKey: .clearLearnToken) ?? 0
        tailEnabled     = try c.decodeIfPresent(Bool.self, forKey: .tailEnabled) ?? false
        tailSymbol      = try c.decodeIfPresent(String.self, forKey: .tailSymbol) ?? ""
        rev             = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
    }

    var sanitized: IMESettings {
        var s = self
        s.candidateCount = min(max(s.candidateCount, IMESettings.candidateRange.lowerBound),
                               IMESettings.candidateRange.upperBound)
        s.outputSpeed = min(max(s.outputSpeed, IMESettings.outputSpeedRange.lowerBound),
                            IMESettings.outputSpeedRange.upperBound)
        if s.tailSymbol.count > 1 { s.tailSymbol = String(s.tailSymbol.prefix(1)) }
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
