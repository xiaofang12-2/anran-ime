import Foundation

/// 主程序 → 键盘的整包交接：布局 + 短语 + 输入设置 + 思想库，一次带过去。
///
/// 纯本地：只走本机回环 TCP（LocalSyncLink）+ Darwin 门铃。
/// 不联网、不上传、不需要账号 / 手机号 / 票据；主程序改完设置，
/// 键盘哪怕正开着也在几十毫秒内收到，全程不出这台手机。
struct SyncBundle: Codable, Equatable {
    var layout: KBConfig?
    var phrases: PhraseBook?
    var settings: IMESettings?
    var thoughts: ThoughtBook?
    /// 刷天帝文本集合
    var brushes: BrushBook?
    var rev: Int = 0
}

enum ConfigSync {

    /// 本机任一 Store 落盘后发（saveLocal 尾部）
    static let localStoreChanged = Notification.Name("anran_local_store_changed")

    /// 键盘侧：上一次接过的整包原文。用内容比对判新旧，比时间戳稳。
    private static let appliedKey = "anran_sync_applied"
    /// 主程序侧：上一次推过的配置内容（不含 rev），没变就不重复按门铃。
    private static let publishedKey = "anran_sync_published"

    /// 组装当前全量配置（rev 置 0，纯粹拿来比对内容）
    private static func snapshot() -> SyncBundle {
        SyncBundle(layout: KBConfigStore.current.sanitized,
                   phrases: PhraseStore.current.sanitized,
                   settings: IMESettingsStore.current.sanitized,
                   thoughts: ThoughtStore.current.sanitized,
                   brushes: BrushStore.current.sanitized,
                   rev: 0)
    }

    private static func encoded(_ b: SyncBundle) -> String? {
        guard let d = try? JSONEncoder().encode(b) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// 主程序用：把当前全量配置落盘并立刻按门铃通知键盘。
    /// 传了哪份就用新值并顺手存本机，没传的取本机现值。
    @discardableResult
    static func publish(layout: KBConfig? = nil,
                        phrases: PhraseBook? = nil,
                        settings: IMESettings? = nil,
                        thoughts: ThoughtBook? = nil,
                        brushes: BrushBook? = nil) -> Bool {
        if let l = layout { KBConfigStore.saveLocal(l) }
        if let p = phrases { PhraseStore.saveLocal(p) }
        if let s = settings { IMESettingsStore.saveLocal(s) }
        if let t = thoughts { ThoughtStore.saveLocal(t) }
        if let b = brushes { BrushStore.saveLocal(b) }

        let snap = snapshot()
        UserDefaults.standard.set(encoded(snap), forKey: publishedKey)
        LocalSyncBridge.ring()
        return true
    }

    /// 配置真变了才按门铃，没变不动 —— 避免每次落盘都让键盘白拉一次。
    @discardableResult
    static func publishIfChanged() -> Bool {
        let snap = snapshot()
        guard let marker = encoded(snap) else { return false }
        if marker == UserDefaults.standard.string(forKey: publishedKey) { return false }
        UserDefaults.standard.set(marker, forKey: publishedKey)
        LocalSyncBridge.ring()
        return true
    }

    /// 纯本地没有「暂存待推」，这里再按一次门铃兜底（切后台 / 页面动作时调）。
    static func flushPending() {
        LocalSyncBridge.ring()
    }

    /// 兼容旧调用点：纯本地版没有服务器可拉，立即回调 false。
    @discardableResult
    static func pullFromServer(_ done: ((Bool) -> Void)? = nil) -> Bool {
        finish(done, false)
        return false
    }

    /// 键盘侧秒同步入口：连主 app 的回环 server 拉整包，内容比上次新就落盘。
    static func pullLocal(_ done: @escaping (Bool) -> Void) {
        LocalSyncLink.fetchBundle { bundle in
            guard let bundle,
                  let json = encoded(bundle) else { finish(done, false); return }
            if json == UserDefaults.standard.string(forKey: appliedKey) {
                done(false)
                return
            }
            apply(bundle)
            UserDefaults.standard.set(json, forKey: appliedKey)
            finish(done, true)
        }
    }

    /// 主 app 侧：当前全量整包（回环 server 的应答数据，每次连接现组）
    static func currentBundle() -> SyncBundle? {
        var b = snapshot()
        b.rev = Int(Date().timeIntervalSince1970 * 1000)
        return b
    }

    /// 整包落盘：配置各归各库，不碰任何账号态。
    private static func apply(_ bundle: SyncBundle) {
        if let l = bundle.layout { KBConfigStore.saveLocal(l) }
        if let p = bundle.phrases { PhraseStore.saveLocal(p) }
        if let s = bundle.settings { IMESettingsStore.saveLocal(s) }
        if let t = bundle.thoughts { ThoughtStore.saveLocal(t) }
        if let b = bundle.brushes { BrushStore.saveLocal(b) }
    }

    /// 完成回调一律回主线程：键盘界面要在回调里改 @State。
    private static func finish(_ done: ((Bool) -> Void)?, _ v: Bool) {
        guard let done else { return }
        if Thread.isMainThread { done(v) } else { DispatchQueue.main.async { done(v) } }
    }
}
