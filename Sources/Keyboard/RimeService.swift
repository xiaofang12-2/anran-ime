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
        let fm = FileManager.default
        guard let resource = Bundle.main.resourceURL else {
            finish(nil, false)
            return
        }
        let shared = resource.appendingPathComponent("rime", isDirectory: true)
        guard fm.fileExists(atPath: shared.path) else {
            // 包里没带 rime 数据（或 CI 没拉到）—— 直接放弃，自研引擎兜底。
            finish(nil, false)
            return
        }
        // 光有空目录（只有 .gitkeep）不算数：必须真带了方案文件，
        // 否则 librime 会拿空 shared 目录去部署，白耗内存还可能卡住。
        let entries = (try? fm.contentsOfDirectory(atPath: shared.path)) ?? []
        let hasSchema = entries.contains { $0.hasSuffix(".schema.yaml") || $0 == "default.yaml" }
        guard hasSchema else {
            finish(nil, false)
            return
        }

        // 用户数据目录必须可写：librime 要在这里放部署好的 bin 和用户词典。
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let userDir = base.appendingPathComponent("rime_user", isDirectory: true)
        try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)

        let b = AnRanRimeBridge(sharedDataDir: shared.path, userDataDir: userDir.path)
        _ = b.setupAndDeploy()
        // 不管成没成都把 bridge 留住：没就绪时还要靠它读出方案 id / 候选条数做诊断。
        finish(b, b.isReady())
    }

    private func finish(_ b: AnRanRimeBridge?, _ ok: Bool) {
        lock.lock()
        bridge = b
        readyFlag = ok
        preparing = false
        lock.unlock()
        // 部署在后台线程，界面得知道结果才能把引擎状态刷出来
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .anranRimeReady, object: nil)
        }
    }

    /// 引擎诊断串：「方案 候选数」，没起来就是「未就绪」。
    /// 键盘空闲时会把这一串显示在候选栏 —— 免费签名没有 App Groups，
    /// 键盘沙箱里的东西主程序读不到，这是确认 librime 到底有没有干活的唯一途径。
    var diagnostics: String {
        lock.lock()
        let b = bridge
        lock.unlock()
        guard let b, let schema = b.activeSchemaId() as String?, !schema.isEmpty else {
            return "未就绪"
        }
        return "\(schema) \(b.probeCandidateCount())"
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
