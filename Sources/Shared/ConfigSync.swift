import Foundation
import UIKit

/// 主程序 → 键盘的整包交接：布局 + 短语 + 输入设置 + 思想库 + 登录态，一次带过去。
///
/// 免费签名用不了 App Groups，只能走剪贴板；而剪贴板只有一个槽，几份配置各写各的
/// 会互相覆盖（推了设置就把短语冲掉、推了登录态就把配置冲掉）。所以合成一个包，
/// 主程序任何一次改动都推全量快照，键盘一次接全。
struct SyncBundle: Codable, Equatable {
    var layout: KBConfig?
    var phrases: PhraseBook?
    var settings: IMESettings?
    var thoughts: ThoughtBook?
    /// 登录态也并进来：以前登录态单独占剪贴板，一推就把配置冲没了。
    var auth: AuthState?
    var rev: Int = 0

    static let prefix = "ANRAN-SYNC::"
}

enum ConfigSync {

    /// 键盘侧：上一次接过的整包原文。用内容比对判新旧 —— 比时间戳稳：
    /// 时钟回拨、同一毫秒连改两条、rev 没来得及变大，都不会把新配置吞掉。
    private static let appliedKey = "anran_sync_applied"
    /// 主程序侧：上一次推过的配置内容（不含 rev）。用来避免切后台时无谓地覆盖用户剪贴板。
    private static let publishedKey = "anran_sync_published"

    /// 组装当前全量配置（rev 置 0，纯粹拿来比对内容）
    private static func snapshot(auth: AuthState? = nil) -> SyncBundle {
        SyncBundle(layout: KBConfigStore.current.sanitized,
                   phrases: PhraseStore.current.sanitized,
                   settings: IMESettingsStore.current.sanitized,
                   thoughts: ThoughtStore.current.sanitized,
                   auth: auth ?? AuthStore.current,
                   rev: 0)
    }

    private static func encoded(_ b: SyncBundle) -> String? {
        guard let d = try? JSONEncoder().encode(b) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 主程序用：把当前全部配置打包塞剪贴板。传了哪份就用新值并顺手存本机，
    /// 没传的取本机现值（这样推任意一份都不会把别的冲掉）。
    @discardableResult
    static func publish(layout: KBConfig? = nil,
                        phrases: PhraseBook? = nil,
                        settings: IMESettings? = nil,
                        thoughts: ThoughtBook? = nil,
                        auth: AuthState? = nil) -> Bool {
        if let l = layout { KBConfigStore.saveLocal(l) }
        if let p = phrases { PhraseStore.saveLocal(p) }
        if let s = settings { IMESettingsStore.saveLocal(s) }
        if let t = thoughts { ThoughtStore.saveLocal(t) }

        var bundle = snapshot(auth: auth)
        bundle.rev = Int(Date().timeIntervalSince1970 * 1000)
        guard let s = encoded(bundle) else { return false }
        if let marker = encoded(snapshot(auth: auth)) {
            UserDefaults.standard.set(marker, forKey: publishedKey)
        }
        UIPasteboard.general.string = SyncBundle.prefix + s
        return true
    }

    /// 主程序切后台时用：配置真变了才推。没变就不动剪贴板，
    /// 免得用户刚复制的字被我们的同步包覆盖掉。
    @discardableResult
    static func publishIfChanged() -> Bool {
        let snap = snapshot()
        guard let marker = encoded(snap) else { return false }
        if marker == UserDefaults.standard.string(forKey: publishedKey) { return false }
        var bundle = snap
        bundle.rev = Int(Date().timeIntervalSince1970 * 1000)
        guard let s = encoded(bundle) else { return false }
        UserDefaults.standard.set(marker, forKey: publishedKey)
        UIPasteboard.general.string = SyncBundle.prefix + s
        return true
    }

    /// 键盘用：剪贴板里有跟上次不一样的整包才接（配置 + 登录态一起落）
    @discardableResult
    static func pull() -> Bool {
        guard let raw = UIPasteboard.general.string,
              raw.hasPrefix(SyncBundle.prefix) else { return false }
        let json = String(raw.dropFirst(SyncBundle.prefix.count))
        guard let d = json.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(SyncBundle.self, from: d) else { return false }
        // 跟上次接过的一模一样就不用再落一遍
        if json == UserDefaults.standard.string(forKey: appliedKey) { return false }
        if let l = bundle.layout { KBConfigStore.saveLocal(l) }
        if let p = bundle.phrases { PhraseStore.saveLocal(p) }
        if let s = bundle.settings { IMESettingsStore.saveLocal(s) }
        if let t = bundle.thoughts { ThoughtStore.saveLocal(t) }
        // 登录态：设备号必须就是本机，防止把别的机器的票据搬过来
        if let a = bundle.auth, !a.ticket.isEmpty, a.machine == DeviceID.current {
            AuthStore.write(a)
        }
        UserDefaults.standard.set(json, forKey: appliedKey)
        return true
    }
}
