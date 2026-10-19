import Foundation

/// 主程序 → 键盘的整包交接：布局 + 短语 + 输入设置 + 思想库 + 登录态，一次带过去。
///
/// 双通道：
/// - 本地链路（秒同步）：主 app 按 Darwin 门铃，键盘直连回环 TCP 拉整包
///   （LocalSyncLink），同设备毫秒级、不碰剪贴板、不要票据、离线可用；
/// - 服务器中转（兜底）：主程序改动全量快照推服务端，键盘凭票据拉，管多设备。
/// 两条路共用 appliedKey 去重，谁先到都不重复落盘。
/// 第一次连接用「配对码」：主程序点「同步数据」出一个6位码，键盘登录墙输一次，之后永久自动同步。
struct SyncBundle: Codable, Equatable {
    var layout: KBConfig?
    var phrases: PhraseBook?
    var settings: IMESettings?
    var thoughts: ThoughtBook?
    /// 登录态并进整包，键盘落包时顺手换新票据
    var auth: AuthState?
    var rev: Int = 0
}

enum ConfigSync {

    /// 本机任一 Store 落盘后发（saveLocal 尾部）。主程序监听它即时推本地总线
    /// + 服务器，键盘下一轮拉取/门铃一响就是新配置。
    static let localStoreChanged = Notification.Name("anran_local_store_changed")

    /// 键盘侧：上一次接过的整包原文。用内容比对判新旧 —— 比时间戳稳：
    /// 时钟回拨、同一毫秒连改两条、rev 没来得及变大，都不会把新配置吞掉。
    private static let appliedKey = "anran_sync_applied"
    /// 主程序侧：上一次推过的配置内容（不含 rev），没变就不重复推。
    private static let publishedKey = "anran_sync_published"
    /// 推送节流：1.5 秒内的连续改动合并成一次请求
    private static var lastPushAt = Date.distantPast
    private static var stagedPush: Data?

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

    /// 主程序用：把当前全部配置推到服务器。传了哪份就用新值并顺手存本机，
    /// 没传的取本机现值（这样推任意一份都不会把别的冲掉）。
    /// 没登录（没票据）时不推，等登录/配对后键盘自然能拉到新包。
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
        guard let marker = encoded(snapshot(auth: auth)) else { return false }
        // 秒同步先行：本地门铃不节流、不等服务器，键盘几十毫秒内来拉
        postLocal()
        push(bundle, marker: marker)
        return true
    }

    /// 主程序切后台/页面动作时用：配置真变了才推，没变不发请求。
    @discardableResult
    static func publishIfChanged() -> Bool {
        let snap = snapshot()
        guard let marker = encoded(snap) else { return false }
        if marker == UserDefaults.standard.string(forKey: publishedKey) { return false }
        var bundle = snap
        bundle.rev = Int(Date().timeIntervalSince1970 * 1000)
        // 同上：本地门铃先行，服务器推送随后（节流/失败都不挡秒同步）
        postLocal()
        push(bundle, marker: marker)
        return true
    }

    /// 推到服务器（带主程序票据）。1.5 秒内的连续改动合并成一次请求。
    /// 「已发布」标记只有推成功才落 —— 失败了重试，保证 publishIfChanged
    /// 在下一个前台时机还能把丢掉的改动补推出去。
    private static func push(_ bundle: SyncBundle, marker: String? = nil) {
        guard let auth = AuthStore.current, !auth.ticket.isEmpty,
              let data = try? JSONEncoder().encode(bundle) else { return }
        stagedPush = data
        let now = Date()
        guard now.timeIntervalSince(lastPushAt) >= 1.5 else {
            scheduleFlush(after: 1.5, marker: marker)
            return
        }
        lastPushAt = now
        AnRanAPI.shared.pushSync(ticket: auth.ticket, data: data) { ok in
            if ok {
                if let marker {
                    UserDefaults.standard.set(marker, forKey: publishedKey)
                }
            } else {
                scheduleFlush(after: 3, marker: marker)
            }
        }
    }

    private static func scheduleFlush(after: TimeInterval, marker: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard let auth = AuthStore.current, !auth.ticket.isEmpty,
                  let staged = stagedPush else { return }
            lastPushAt = Date()
            AnRanAPI.shared.pushSync(ticket: auth.ticket, data: staged) { ok in
                if ok {
                    if let marker {
                        UserDefaults.standard.set(marker, forKey: publishedKey)
                    }
                } else {
                    scheduleFlush(after: 3, marker: marker)
                }
            }
        }
    }

    /// 同设备秒同步：按下 Darwin 门铃（不带数据）。键盘听到会自己去
    /// 回环 TCP（LocalSyncLink）拉最新整包。与服务器推送并存 ——
    /// 门铃管本机毫秒级（键盘哪怕正开着也能立刻收到），服务器管多设备。
    /// 没登录（没票据）也按：本地同步不依赖票据。
    private static func postLocal() {
        LocalSyncBridge.ring()
    }

    /// 主程序切后台前调：把暂存的改动立刻推出去，别被节流窗口咽掉。
    static func flushPending() {
        guard let auth = AuthStore.current, !auth.ticket.isEmpty,
              let staged = stagedPush else { return }
        lastPushAt = Date()
        AnRanAPI.shared.pushSync(ticket: auth.ticket, data: staged)
    }

    /// 键盘用：从服务器拉最新整包（异步，不卡首帧）。
    /// 拉到跟上次不一样的新包就落盘（配置 + 登录态一起），回调 true。
    /// 网络失败自动补拉一次（键盘扩展偶发没网/半断网，不补就滞后到下次弹出）。
    @discardableResult
    static func pullFromServer(_ done: ((Bool) -> Void)? = nil) -> Bool {
        guard let auth = AuthStore.current, !auth.ticket.isEmpty else {
            done?(false)
            return false
        }
        attemptPull(ticket: auth.ticket, allowRetry: true, done)
        return true
    }

    private static func attemptPull(ticket: String, allowRetry: Bool,
                                    _ done: ((Bool) -> Void)?) {
        AnRanAPI.shared.pullSync(ticket: ticket) { data in
            guard let data,
                  let bundle = try? JSONDecoder().decode(SyncBundle.self, from: data) else {
                if data == nil, allowRetry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        attemptPull(ticket: ticket, allowRetry: false, done)
                    }
                    return
                }
                done?(false)
                return
            }
            let json = String(data: data, encoding: .utf8) ?? ""
            if json == UserDefaults.standard.string(forKey: appliedKey) {
                done?(false)
                return
            }
            apply(bundle)
            UserDefaults.standard.set(json, forKey: appliedKey)
            done?(true)
        }
    }

    /// 整包落盘：配置各归各库，登录态只收本机设备的票据
    private static func apply(_ bundle: SyncBundle) {
        if let l = bundle.layout { KBConfigStore.saveLocal(l) }
        if let p = bundle.phrases { PhraseStore.saveLocal(p) }
        if let s = bundle.settings { IMESettingsStore.saveLocal(s) }
        if let t = bundle.thoughts { ThoughtStore.saveLocal(t) }
        if let a = bundle.auth, !a.ticket.isEmpty, a.machine == DeviceID.current {
            AuthStore.write(a)
        }
    }

    /// 键盘侧秒同步入口：连主 app 的回环 server 拉整包，内容比上次新就落盘。
    /// 与服务器拉取共用 appliedKey 去重标记 —— 两条路谁先到都不重复落盘。
    /// 主 app 没在跑（连不上/超时）→ false，调用方照旧走服务器。
    static func pullLocal(_ done: @escaping (Bool) -> Void) {
        LocalSyncLink.fetchBundle { bundle in
            guard let bundle else { done(false); return }
            guard let json = encoded(bundle) else { done(false); return }
            if json == UserDefaults.standard.string(forKey: appliedKey) {
                done(false)
                return
            }
            apply(bundle)
            UserDefaults.standard.set(json, forKey: appliedKey)
            done(true)
        }
    }

    /// 主 app 侧：当前全量整包（回环 server 的应答数据，每次连接现组）
    static func currentBundle() -> SyncBundle? {
        var b = snapshot()
        b.rev = Int(Date().timeIntervalSince1970 * 1000)
        return b
    }
}
