import Foundation
import UIKit

/// 主程序 → 键盘的整包交接：布局 + 短语 + 输入设置一次带过去。
///
/// 免费签名用不了 App Groups，只能走剪贴板；而剪贴板只有一个槽，
/// 三份配置各写各的会互相覆盖（推了设置就把布局冲掉）。所以合成一个包，
/// 主程序点任意「应用」都推全量快照，键盘一次接全。
struct SyncBundle: Codable, Equatable {
    var layout: KBConfig?
    var phrases: PhraseBook?
    var settings: IMESettings?
    var thoughts: ThoughtBook?
    var rev: Int = 0

    static let prefix = "ANRAN-SYNC::"
}

enum ConfigSync {

    private static let revKey = "anran_sync_rev"

    private static var appliedRev: Int {
        get { UserDefaults.standard.integer(forKey: revKey) }
        set { UserDefaults.standard.set(newValue, forKey: revKey) }
    }

    /// 主程序用：把当前三份配置打包塞剪贴板。传了哪份就用新值并顺手存本机，
    /// 没传的取本机现值（这样推任意一份都不会把另两份冲掉）。
    @discardableResult
    static func publish(layout: KBConfig? = nil,
                        phrases: PhraseBook? = nil,
                        settings: IMESettings? = nil,
                        thoughts: ThoughtBook? = nil) -> Bool {
        if let l = layout { KBConfigStore.saveLocal(l) }
        if let p = phrases { PhraseStore.saveLocal(p) }
        if let s = settings { IMESettingsStore.saveLocal(s) }
        if let t = thoughts { ThoughtStore.saveLocal(t) }

        var bundle = SyncBundle(
            layout: KBConfigStore.current.sanitized,
            phrases: PhraseStore.current.sanitized,
            settings: IMESettingsStore.current.sanitized,
            thoughts: ThoughtStore.current.sanitized)
        bundle.rev = Int(Date().timeIntervalSince1970)
        guard let d = try? JSONEncoder().encode(bundle),
              let s = String(data: d, encoding: .utf8) else { return false }
        UIPasteboard.general.string = SyncBundle.prefix + s
        return true
    }

    /// 键盘用：剪贴板里有更新的整包才接
    @discardableResult
    static func pull() -> Bool {
        guard let raw = UIPasteboard.general.string,
              raw.hasPrefix(SyncBundle.prefix) else { return false }
        let json = String(raw.dropFirst(SyncBundle.prefix.count))
        guard let d = json.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(SyncBundle.self, from: d) else { return false }
        guard bundle.rev > appliedRev else { return false }
        if let l = bundle.layout { KBConfigStore.saveLocal(l) }
        if let p = bundle.phrases { PhraseStore.saveLocal(p) }
        if let s = bundle.settings { IMESettingsStore.saveLocal(s) }
        if let t = bundle.thoughts { ThoughtStore.saveLocal(t) }
        appliedRev = bundle.rev
        return true
    }
}
