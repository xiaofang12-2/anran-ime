import Foundation

/// 键盘扩展内的 librime 服务。
///
/// **不是 XPC** —— 同进程直接调（iOS 第三方键盘拿不到 IPC 通道，见
/// docs/ARCHITECTURE.md §0.1）。librime 静态链进扩展，C API 走 RimeBridge。
///
/// 首次 `prepare()` 会把随包带的预编译词库（`Resources/rime`）落到扩展沙盒里，
/// 之后秒开。整条链路任何一步失败都不会崩 —— 上层退回自研引擎。
final class RimeService {

    static let shared = RimeService()

    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "anran.rime.prepare", qos: .userInitiated)

    private var bridge: AnRanRimeBridge?
    private var preparing = false
    private var readyFlag = false

    /// 加载失败原因（真机角标会显示，用来判断为什么退回了自研引擎）
    private enum FailureKind { case missing, transient }
    private var lastFailureKind: FailureKind = .missing
    private var lastFailureReason = ""
    private var retryCount = 0

    /// 瞬时失败（部署没起来，多半是首启内存抖动/后台抢资源）的有限重试次数与间隔
    private static let maxRetry = 2
    private static let retryDelay: DispatchTimeInterval = .milliseconds(1500)

    private init() {}

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return readyFlag
    }

    /// librime 版本号（没起来就是空串），用于「设置 → 关于」显示引擎状态
    var engineVersion: String {
        lock.lock(); defer { lock.unlock() }
        return bridge?.rimeVersion() ?? ""
    }

    /// 首次准备。异步，不阻塞键盘首帧。
    func prepare() {
        lock.lock()
        if readyFlag || preparing {
            lock.unlock()
            return
        }
        preparing = true
        lock.unlock()

        workQueue.async { [weak self] in
            self?.doPrepare()
        }
    }

    private func doPrepare() {
        lock.lock(); preparing = true; lock.unlock()

        let fm = FileManager.default
        guard let resource = Bundle.main.resourceURL else {
            finish(nil, false, kind: .missing, reason: "缺包资源")
            return
        }
        let shared = resource.appendingPathComponent("rime", isDirectory: true)
        guard fm.fileExists(atPath: shared.path) else {
            // 包里没带 rime 数据（或 CI 没拉到）—— 直接放弃，自研引擎兜底。
            finish(nil, false, kind: .missing, reason: "缺词库")
            return
        }
        // 光有空目录（只有 .gitkeep）不算数：必须真带了方案文件，
        // 否则 librime 会拿空 shared 目录去部署，白耗内存还可能卡住。
        let entries = (try? fm.contentsOfDirectory(atPath: shared.path)) ?? []
        let hasSchema = entries.contains { $0.hasSuffix(".schema.yaml") || $0 == "default.yaml" }
        guard hasSchema else {
            finish(nil, false, kind: .missing, reason: "缺方案")
            return
        }

        // 用户数据目录必须可写：librime 要在这里放部署好的 bin 和用户词典。
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let userDir = base.appendingPathComponent("rime_user", isDirectory: true)
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)

        let b = AnRanRimeBridge(sharedDataDir: shared.path, userDataDir: userDir.path)
        _ = b.setupAndDeploy()
        if b.isReady() {
            finish(b, true)
        } else {
            // 部署没起来：先留住 bridge 做诊断；按「瞬时失败」有限重试，
            // 多半是首启内存抖动 / 后台线程抢资源，过一会儿再试往往就成。
            finish(b, false, kind: .transient, reason: "部署失败")
        }
    }

    /// ok=true 时清掉失败记录并允许后续重试；ok=false 时记下失败种类与原因，
    /// 瞬时失败且未超上限则延迟重试一次。
    private func finish(_ b: AnRanRimeBridge?, _ ok: Bool,
                        kind: FailureKind = .missing, reason: String = "") {
        var shouldRetry = false
        lock.lock()
        bridge = b
        readyFlag = ok
        preparing = false
        if ok {
            lastFailureKind = .missing
            lastFailureReason = ""
            retryCount = 0
        } else {
            lastFailureKind = kind
            lastFailureReason = reason
            if kind == .transient, retryCount < RimeService.maxRetry {
                shouldRetry = true
                retryCount += 1
            }
        }
        lock.unlock()
        // 部署在后台线程，界面得知道结果才能把引擎状态刷出来
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .anranRimeReady, object: nil)
        }
        if shouldRetry {
            workQueue.asyncAfter(deadline: .now() + RimeService.retryDelay) { [weak self] in
                self?.doPrepare()
            }
        }
    }

    /// 引擎诊断串：「方案 候选数」，没起来就是「未就绪」。
    /// 键盘空闲时会把这一串显示在候选栏 —— 免费签名没有 App Groups，
    /// 键盘沙箱里的东西主程序读不到，这是确认 librime 到底有没有干活的唯一途径。
    var diagnostics: String {
        lock.lock()
        let b = bridge
        let ok = readyFlag
        let reason = lastFailureReason
        lock.unlock()
        guard ok, let b, let schema = b.activeSchemaId() as String?, !schema.isEmpty else {
            return reason.isEmpty ? "未就绪" : "未就绪·\(reason)"
        }
        return "\(schema) \(b.probeCandidateCount())"
    }

    /// 顶栏用的简短引擎角标：用户一眼看出当前是谁在出字。
    /// 雾凇/鼠须管方案就绪 → "雾凇·30"（30 = 打 nihao 能出的候选数，越大越健康）；
    /// 没起来 → "自研兜底" 或 "自研兜底·缺方案" / "自研兜底·部署失败" 等，
    /// 把退回自研的真实原因亮出来 —— 这是「为什么我打出来跟百度差这么远」的第一手线索。
    var engineBadge: String {
        lock.lock()
        let b = bridge
        let ok = readyFlag
        let reason = lastFailureReason
        lock.unlock()
        guard ok, let b else { return reason.isEmpty ? "自研兜底" : "自研兜底·\(reason)" }
        let sch = (b.activeSchemaId() as String?) ?? ""
        let cnt = b.probeCandidateCount()
        return "\(sch)·\(cnt)"
    }

    // MARK: - 候选

    /// 取 librime 候选。未就绪返回空数组（上层会退回自研引擎）。
    func candidates(_ input: String, limit: Int = 40) -> [AnRanRimeCandidate] {
        lock.lock()
        let b = bridge
        lock.unlock()
        guard let b else { return [] }
        return b.candidates(forInput: input, limit: limit)
    }

    /// 选中第 index 条候选：librime 会顺手把这词学进用户词典。
    @discardableResult
    func select(index: Int) -> String? {
        lock.lock()
        let b = bridge
        lock.unlock()
        return b?.selectCandidate(at: index)
    }

    /// 上屏后 librime 里还剩多少没消化的拼音串（支持部分上屏）
    func currentInput() -> String {
        lock.lock()
        let b = bridge
        lock.unlock()
        return b?.currentInput() ?? ""
    }

    func learn(word: String, input: String) {
        lock.lock()
        let b = bridge
        lock.unlock()
        b?.learnWord(word, input: input)
    }

    func reset() {
        lock.lock()
        let b = bridge
        lock.unlock()
        b?.reset()
    }

    func setOption(_ name: String, _ value: Bool) {
        lock.lock()
        let b = bridge
        lock.unlock()
        b?.setOption(name, value: value)
    }
}
