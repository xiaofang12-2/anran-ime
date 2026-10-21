// 评测用的最小桩：只提供 PinyinEngine 编译所需的类型，
// 避免把 ConfigSync / 网络 / 认证那一大坨依赖拖进来（否则命令行工具编不过）。
//
// ⚠️ 这些桩**只用于 tools/eval**，不参与 App/扩展的构建。
import Foundation

/// 设置项：只保留引擎真正读的字段
struct IMESettings {
    var fuzzyPinyin = true
    var abbrevInput = true
    var smartCorrect = true
    var candidateCount = 40
}

enum IMESettingsStore {
    static var current = IMESettings()
}

/// 自定义短语
struct Phrase: Equatable {
    var id = ""
    var code = ""
    var text = ""
    var position = 1

    /// 触发码（去空白）；引擎按它精确匹配
    var cleanCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
