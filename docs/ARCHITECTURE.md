# 黯然输入法 iOS · 架构设计 v2（混合引擎方案）

> 版本：2026-10-11 · 对应客户端 v0.3.5
> 目标：拼音手感对标并超越百度输入法；**复用工业级开源内核，不重复造轮子**。

---

## 0. 先说三条 iOS 硬约束

这三条是苹果系统能力层面的死线，不改它们，方案落不了地。逐条对照原始需求给出修正。

### 0.1 ❌ 「键盘扩展 XPC 调宿主 App 的 librime 服务」在 iOS 上做不到

iOS 的第三方 **App Extension 与宿主 App 之间没有公开的 IPC 通道**：

- 扩展是**独立进程**，宿主 App 在扩展运行时通常根本不在运行；
- `NSXPCConnection` 只能连**系统服务**或**自带特权 entitlement 的 Mach service**，第三方键盘拿不到这类 entitlement；
- 苹果官方给 App 与扩展之间只留了 **App Groups（共享存储）**，那是「共享文件」，不是「实时服务调用」。

> **修正**：librime **静态链进键盘扩展自身**，在**同一进程内**用 C API 调用。
> 这是 iRime、小鹤音形等所有 iOS Rime 键盘的唯一做法，也是唯一能实时出候选的做法。

### 0.2 ⚠️ 免费自签没有 App Groups

`com.apple.security.application-groups` 属**付费开发者能力**，免费配置档不含。一旦声明，Sideloadly / SideStore 自签会直接失败（`app group invalid`），整包装不上。

> 本项目两个 entitlements **已刻意留空**（见 `Support/*/*.entitlements` 内注释）。
> 主 App ↔ 扩展的配置交接走**剪贴板整包**（`ConfigSync`，已实现）。
> 将来用付费账号或巨魔商店专属包，把 entitlement 加回来，`SharedStore` 会自动切到共享容器，上层代码零改动。

### 0.3 ❌ 扩展里跑不了 7B 模型

扩展内存硬限 **30~60MB**，超了被 jetsam **静默杀掉**（无崩溃日志，键盘直接消失）。7B 权重 4GB+，物理上塞不进。

> **修正**：「Qwen7B 实时重排候选」**不可行**（既不能 XPC 到宿主，也塞不进扩展）。
> Qwen 只能做成**宿主 App 内的离线「智能回复 / 改写」**，与候选栏解耦，**默认关闭**。
> 候选栏的实时增强只保留**纯本地、内存可控**的层（用户词典 + 短语 + 可选的小向量索引）。

---

## 1. 目标架构（修正后）

```
┌──────────────────────────────────────────────────────────────┐
│ AnRanKeyboard.appex   键盘扩展进程（内存 30~60MB 硬顶）          │
│                                                               │
│   KeyboardRootView ──按键──►  InputEngine（Swift 轻量壳）       │
│                                    │  字母串 + 参数             │
│                                    │  (模糊音/双拼/简拼/纠错)    │
│                                    ▼                          │
│                              RimeBridge（ObjC++ 薄封装）        │
│                                    │  librime C API           │
│                                    ▼                          │
│                              librime.a（arm64 静态库）          │
│                                · 音节切分 / 简拼 / 双拼          │
│                                · 模糊音 / 多音字 / 错拼纠错       │
│                                · 基础候选生成                    │
│                                    │  基础候选                 │
│                                    ▼                          │
│                              Ranker（我们的差异化增强层）        │
│                                ① 用户词典（librime user_dict）  │
│                                ② 自定义短语命中（PhraseStore）   │
│                                ③ 小型向量索引语义微调（可选）      │
│                                    │                          │
│                                    ▼                          │
│                              候选栏渲染                          │
│                                                               │
│   Support/dict/*.bin  ── mmap 按页懒加载（不占常驻内存）          │
└──────────────────────────────────────────────────────────────┘
                     │  剪贴板整包（免费签名）
                     │  App Group 共享容器（付费账号 / 巨魔商店）
                     ▼
┌──────────────────────────────────────────────────────────────┐
│ AnRanIME.app   宿主主程序                                       │
│   · 账号登录 / 心跳 / 证书固定（AnRanAPI + AuthStore）           │
│   · 键盘布局编辑 / 自定义短语 / 输入设置                          │
│   · Qwen7B 离线智能回复（默认关，不参与候选栏）                    │
│   · 词库热更新包下载与校验                                        │
│   · ConfigSync.publish() → 剪贴板整包                            │
└──────────────────────────────────────────────────────────────┘
```

**数据流（一次按键）：**

```
按键 → InputEngine 收集字母 → RimeBridge → librime 出基础候选
     → Ranker 三层加权（用户词典 > 短语 > 向量语义） → 候选栏
选中 → 上屏 → librime 学习该词（写 user_dict）
```

---

## 2. 模块依赖

| 模块 | 文件 | 依赖 | 职责 |
|---|---|---|---|
| 键盘界面 | `Keyboard/KeyboardRootView.swift`、`KeyViews.swift`、`KeyboardLayout.swift` | InputEngine | 26 键布局、候选栏、按键音 |
| 输入引擎壳 | `Keyboard/InputEngine.swift`（新增） | RimeBridge、Ranker、KBConfig、PhraseStore | 收集字母、参数透传、编排「取候选 → 重排」 |
| Rime 封装 | `Keyboard/RimeBridge.h/.mm`（新增） | librime.a | ObjC++ 薄封装，把 C API 暴露给 Swift |
| Rime 内核 | `ThirdParty/librime/librime.a`（新增） | boost / yaml-cpp / leveldb / glog / utf8proc | 切分 / 简拼 / 双拼 / 模糊音 / 多音字 / 纠错 / 基础候选 |
| 重排层 | `Keyboard/Ranker.swift`（新增） | RimeBridge、PhraseStore、UserDict | 三层加权 |
| 用户词典 | `Keyboard/UserDict.swift`（新增，或直接用 librime user_dict） | — | 学习/记忆用户用词 |
| 共享层 | `Shared/*.swift` | — | 配置/短语/登录态的存储与交接 |
| 主程序 | `HostApp/*.swift` | Shared | 登录、布局编辑、短语、设置、Qwen 离线 |
| 构建 | `project.yml`、`.github/workflows/ios.yml` | xcodegen | 云 Mac 交叉编译 + 出包 |

**依赖方向（禁止反向）：**

```
KeyboardRootView → InputEngine → { RimeBridge → librime , Ranker → UserDict/PhraseStore }
HostApp → Shared ← Keyboard          （Shared 是唯一双向共享层）
```

---

## 3. librime 集成方案

### 3.1 为什么是 librime

- **BSD-3-Clause**，可闭源商用，**保留版权头即可**，与本项目现有「不引入 GPL」的底线兼容；
- 工业级成熟：切分、简拼、双拼、模糊音、多音字、错拼纠错、词图 + n-gram 全都有；
- 大量商业输入法同源，词库生态（rime-ice 等）现成。

> ⚠️ **词库许可要单独核**：librime **代码**是 BSD-3（安全）；但 `rime-ice` 等**词库数据**的许可另算（社区常见 CC-BY-4.0 / MIT 说法不一），商用前必须逐份核对并保留署名。不要把 GPL 系键盘的代码搬进来。

### 3.2 交叉编译（在云 Mac CI 里做，本机 Windows 编不了）

产出 `librime.a`（arm64，iphoneos + iphonesimulator 各一份，合成 xcframework）。

依赖（全部需 arm64 交叉编译）：

| 依赖 | 用途 | 许可 |
|---|---|---|
| boost（header-only 部分为主） | 基础库 | BSL-1.0 |
| yaml-cpp | 读 rime 配置 | MIT |
| leveldb | 用户词典存储 | BSD-3 |
| glog | 日志 | BSD-3 |
| utf8proc | UTF-8 处理 | MIT |

CI 步骤（新增到 `ios.yml`）：

1. 拉源码（librime + 依赖，固定 tag）；
2. 用 CMake 工具链（`-DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64`）逐库编译；
3. `xcodebuild -create-xcframework` 合成；
4. 缓存产物，避免每次全量重编（一次约 30~60 分钟）。

### 3.3 词库

- 用 **librime 标准格式**词库（`.prism.bin` / `.table.bin` / `.reverse.bin`），**不是**现有自研的 `pinyin.bin`；
- 体积大不是问题：librime 的 `TableAccessor` 用 **mmap**，**常驻内存只算触碰过的页**，不是「文件多大内存就多大」；
- 但 `.prism.bin`（词图前缀）与用户词典在内存里构建，需实测扩展峰值，必要时精简词库；
- **热更新**：主程序下载增量热词包 → 校验 sha256 → 剪贴板/共享容器交给扩展。

### 3.4 与现有自研引擎的关系

**保留现有 `PinyinEngine.swift` 作为兜底**（librime 初始化失败 / 内存告急时顶上），避免内核起不来就完全不能打字。两者实现同一个 `PinyinService` 协议，切换只改注入。

---

## 4. 布局 JSON 数据结构

现有 `KBConfig` 是**全局参数**（键高/间距/圆角/字号/边距）。按需求「用户自行调整 26 字母按键的宽高」，扩展为**全局参数 + 每键覆盖**。

### 4.1 当前（v0.3.5，已上线）

```json
{
  "keyHeight": 45, "keyGap": 6, "rowGap": 6, "corner": 6,
  "fontScale": 1.0, "sideInset": 3, "bottomInset": 5, "rev": 1730000000
}
```

### 4.2 目标（扩展后）

```json
{
  "schema": 2,
  "global": {
    "keyHeight": 45, "keyGap": 6, "rowGap": 6,
    "corner": 6, "fontScale": 1.0, "sideInset": 3, "bottomInset": 5
  },
  "rows": [
    { "keys": ["q","w","e","r","t","y","u","i","o","p"] },
    { "keys": ["a","s","d","f","g","h","j","k","l"] },
    { "keys": ["shift","z","x","c","v","b","n","m","backspace"] },
    { "keys": ["123","space","return"] }
  ],
  "overrides": {
    "space": { "width": 5.0, "height": 45, "corner": 6 },
    "return": { "width": 2.0 }
  },
  "rev": 1730000000
}
```

**字段语义**

| 字段 | 类型 | 说明 |
|---|---|---|
| `schema` | Int | 结构版本；`1`=老扁平格式，`2`=本格式，读老格式自动升级 |
| `global.keyHeight` | Double | 字母键基准高度（pt），范围 34~70 |
| `global.keyGap` / `rowGap` | Double | 横/纵间距，2~14 |
| `global.corner` | Double | 键帽圆角，0~16 |
| `global.fontScale` | Double | 字号缩放，0.7~1.5 |
| `global.sideInset` / `bottomInset` | Double | 左右/底部留白，0~16 |
| `rows[].keys` | [String] | 该行按键，字符串为键位标识（字母 / 功能键名） |
| `overrides` | Map | 单键覆盖：`width` 以「字母键宽」为 1.0 的倍数，`height` 为 pt |
| `rev` | Int | 版本戳（Unix 秒），键盘按它判新旧，防止旧配置盖新配置 |

**兼容规则**：`schema` 缺省按 `1` 处理；老格式读进来后由 `KBConfig.migrate()` 升级成 `2`，`overrides` 为空。所有数值出口统一过 `sanitized`（夹到合法范围），避免用户拖出不可用键盘。

---

## 5. App Group / 共享存储读写方案

### 5.1 双通道设计（同一套上层代码）

```
SharedStore.rootURL
   ├─ 优先：FileManager.containerURL(forSecurityApplicationGroupIdentifier:)
   │         → 付费账号 / 巨魔商店可用
   └─ 回退：本 app 沙盒 documentDirectory
             → 免费签名走这条，两边各自沙盒，靠剪贴板交接
```

现有 `SharedStore` 已经是这个结构，**无需改动**，付费能力恢复时自动生效。

### 5.2 配置交接时序（免费签名，剪贴板整包）

```
主 App（设置/布局/短语/登录态）
   │ 用户点「应用 / 同步」
   ▼
ConfigSync.publish(layout:phrases:settings:)
   │ 1) 各自 saveLocal（主 App 沙盒）
   │ 2) 合成 SyncBundle{layout,phrases,settings,rev=now}
   │ 3) UIPasteboard.general.string = "ANRAN-SYNC::" + json
   ▼
（用户切到键盘）
   ▼
键盘 ConfigSync.pull()
   │ 读剪贴板 → 前缀匹配 → 解 JSON → rev 比本地新才采纳
   ▼
KBConfigStore / PhraseStore / IMESettingsStore 更新 → 引擎与界面生效
```

**要点**

- **整包交接**：剪贴板只有一个槽，三份配置各写各的会互相覆盖，所以合成一个 `SyncBundle` 一次带过去；
- **rev 单调**：`rev = 当前时间戳`，键盘只采纳更新的，旧包不覆盖新包；
- **登录态单独通道**：`AuthStore` 用 `ANRAN-AUTH::` 前缀，票据里的设备码必须等于本机，防搬票；
- **剪贴板会弹系统确认**：挡不掉，属预期行为（README 已注明）。

### 5.3 App Group 恢复时（付费/巨魔）

- 给两个 target 的 entitlements 加 `com.apple.security.application-groups = [group.com.anran.ime]`；
- `SharedStore` 自动切到共享容器，`ConfigSync` 可退化为「只写共享容器 + Darwin 通知」，不再依赖剪贴板；
- 上层 `PinyinService` / 引擎代码**零改动**。

---

## 6. 候选服务接口定义（InputEngine ↔ 拼音服务）

> **原需求写的是「XPC 接口」。按 0.1，XPC 在第三方键盘上不可用。**
> 这里把它定义成**传输无关的服务协议** `PinyinService`：
> **当前实现 = 进程内直接调用**（`RimeService` 包装 librime）。
> 接口本身与传输解耦 —— 哪天苹果开放系统级输入法或改用特权通道，只换实现，协议不动。

### 6.1 数据结构

```swift
import Foundation

/// 输入方案
enum PinyinScheme: String, Codable {
    case full      // 全拼
    case abbrev    // 简拼 / 混拼
    case shuangpin // 双拼（scheme 名在 extra 里，如 "flypy" 小鹤）
}

/// 一条候选
struct PinyinCandidate: Codable, Equatable {
    let word: String      // 候选词
    let score: Int        // 统一打分（越大越靠前）
    let consumed: Int     // 吃掉输入串多少字符（支持部分上屏）
    let literal: Bool     // 是否「原样英文」候选
    let source: Source    // 来自哪一层（调试/统计用）

    enum Source: String, Codable { case rime, user, phrase, vector, literal }
}

/// 请求
struct PinyinRequest {
    var input: String                 // 已收集字母串，如 "xbzz"
    var scheme: PinyinScheme = .full
    var shuangpinName: String? = nil  // 双拼方案名
    var fuzzy: Bool = true            // 模糊音
    var smartCorrect: Bool = true     // 错拼纠错
    var limit: Int = 40
    var context: [String] = []        // 上文已上屏词（供重排/预测）
    var rev: Int = 0                  // 配置版本戳，变了才重载配置
}

/// 应答
struct PinyinResponse {
    var candidates: [PinyinCandidate]
    var composing: String             // 未消化的剩余拼音串
    var rev: Int
}

/// 配置快照（键盘侧从剪贴板/共享容器拉到的）
struct PinyinConfig {
    var phrases: [Phrase] = []
    var userWords: [String: [String]] = [:]   // 拼音 -> 用户自造词
    var rev: Int = 0
}
```

### 6.2 服务协议

```swift
/// 拼音服务：键盘的 InputEngine 只依赖这个协议，不关心底下是 librime 还是自研引擎。
protocol PinyinService: AnyObject {

    /// 首次准备（加载词库/建索引）。异步，不阻塞首帧。
    /// - Parameter progress: 0.0~1.0，界面可显示「词库加载中」
    func prepare(progress: ((Double) -> Void)?) async

    /// 是否已就绪；未就绪时 InputEngine 退回兜底引擎
    var isReady: Bool { get }

    /// 取候选（热路径，必须快；内部不许做同步 IO）
    func candidates(_ req: PinyinRequest) -> PinyinResponse

    /// 用户上屏一个词：交给内核学习（写 user_dict）
    func commit(word: String, input: String)

    /// 应用一份新配置（短语/用户词/开关）
    func apply(_ config: PinyinConfig)

    /// 重置当前组字（清空未消化拼音）
    func reset()
}
```

### 6.3 实现：进程内 `RimeService`（包装 librime）

```swift
/// 键盘扩展内的 librime 服务。**不是 XPC** —— 同进程直接调用（见架构 §0.1）。
final class RimeService: PinyinService {

    private let bridge: RimeBridge        // ObjC++ 薄封装，持有 librime 会话
    private var ready = false
    private var appliedRev = -1

    init(sharedDir: URL, userDir: URL) {
        // 词库/配置从扩展 bundle 或共享目录来；userDir 可写（用户词典落这）
        bridge = RimeBridge(sharedDataDir: sharedDir.path,
                            userDataDir: userDir.path)
    }

    var isReady: Bool { ready }

    func prepare(progress: ((Double) -> Void)?) async {
        // librime 初始化（部署/加载词库）放后台线程，不卡首帧
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.bridge.deploy()
                self?.ready = self?.bridge.isReady ?? false
                progress?(1.0)
                cont.resume()
            }
        }
    }

    func candidates(_ req: PinyinRequest) -> PinyinResponse {
        guard ready else { return PinyinResponse(candidates: [], composing: req.input, rev: req.rev) }
        // 参数透传（模糊音/双拼/简拼）由 RimeBridge 映射到 librime 的 schema 选项
        let raw = bridge.candidates(input: req.input,
                                    scheme: req.scheme,
                                    fuzzy: req.fuzzy,
                                    smartCorrect: req.smartCorrect,
                                    limit: req.limit)
        return PinyinResponse(candidates: raw, composing: bridge.composing, rev: req.rev)
    }

    func commit(word: String, input: String) { bridge.learn(word: word, input: input) }
    func reset() { bridge.reset() }

    func apply(_ config: PinyinConfig) {
        guard config.rev != appliedRev else { return }   // rev 没变不重载
        appliedRev = config.rev
        bridge.setPhrases(config.phrases.map { ($0.cleanCode, $0.text) })
        bridge.setUserWords(config.userWords)
    }
}
```

### 6.4 传输无关的边界（为什么这么设计）

| 需求原文 | 现实 | 本方案 |
|---|---|---|
| 扩展 XPC 调宿主 App 的 librime | ❌ iOS 不给第三方键盘 IPC | librime 链进扩展，**同进程调用** |
| librime 跑宿主 App | ❌ 宿主可能没运行，扩展够不着 | 内核随扩展走 |
| Qwen7B 重排候选 | ❌ 塞不进扩展、也没法 XPC | Qwen 移到宿主 App 做**离线智能回复**，默认关 |
| 向量语义重排 | ⚠️ 25 万词向量塞不进扩展 | 只保留**小型精简索引**，超内存就整层关闭 |

---

## 7. 分模块迭代计划

| 步 | 内容 | 验收 |
|---|---|---|
| A | CI 交叉编译 librime → xcframework，产出可链接静态库 | CI 绿，`librime.a` 落 artifact |
| B | `RimeBridge`（ObjC++）+ `PinyinService` 协议 + `RimeService` 骨架，链进扩展能编译 | 装进手机键盘不崩，`prepare()` 成功 |
| C | 词库打包进扩展，`InputEngine` 接 librime 出候选 | `xbzz→小逼崽子`、`za→咋/咱`、`nh→你好` 全中 |
| D | `Ranker` 三层加权（用户词典/短语/向量） | 选过的词下次靠前；短语码即时展开 |
| E | 全拼/简拼/双拼/模糊音/多音字/纠错开关打通 | 各方案切换正确出词 |
| F | 布局 schema v2（每键宽高覆盖）+ 主程序编辑页 | 主程序调宽高，键盘实时生效 |
| G | 词库热更新（下载 → sha256 校验 → 交接） | 热词包更新后新词可打 |
| H | Qwen 离线智能回复（宿主 App，默认关） | 与候选栏解耦，开关可控 |

---

## 8. iOS 坑点 + 单元测试

### 8.1 坑点清单

1. **扩展内存**：任何「一次性把词库读进堆」的写法都会在真机上被 jetsam 杀；librime 词库必须 mmap，自研兜底引擎同理。
2. **扩展进程无 UI 提示**：崩溃无日志，排查靠 `Console.app` 过滤扩展进程名。
3. **剪贴板弹确认**：读剪贴板系统会提示，挡不掉，配置交接频率要低（只在用户点「应用」时推）。
4. **App Groups 声明即自签失败**：免费签名期间两个 entitlements 必须留空。
5. **librime 初始化耗时**：部署/建索引可能数秒，必须后台线程 + 进度回调，不能卡键盘首帧。
6. **ObjC++ 与 Swift 桥**：`RimeBridge` 用 `.mm`，暴露 `@objc` 接口；C++ 异常不能穿过 Swift 边界。
7. **双拼/简拼参数**：librime 通过 schema 的 `speller` 选项控制，切换方案要重建会话或切 schema，成本高，需缓存。
8. **用户词典落盘**：`userDir` 必须在扩展可写目录（`SharedStore` 或扩展沙盒），免费签名下主 App 读不到。
9. **许可合规**：librime 保留 BSD 版权头；词库数据逐份核许可并署名。
10. **兜底不丢**：librime 起不来必须静默退回自研 `PinyinEngine`，主功能永不可用性为零。

### 8.2 单元测试（在 CI 的 macos runner 上跑，或本机 Python 参考端对齐）

| 用例 | 期望 |
|---|---|
| `full("xbzz")` | 首位 `小逼崽子` |
| `full("za")` | 前 5 含 `在/咱/咋`（不再只出「再见」） |
| `full("nh")` | 首位 `你好` |
| `full("zme")` | 首位 `怎么` |
| `full("woxihuanni")` | 首位 `我喜欢你` |
| `abbrev("nizaiganma")` | 首位 `你在干嘛`（或带语气词） |
| `fuzzy("zhidaole")` | 首位 `知道了` |
| `commit("小逼崽子")` 后再 `full("xbzz")` | 该词仍/更靠前（学习生效） |
| `phrase("dz")` | 展开为自定义短语全文 |
| 内存 | `prepare()` 后扩展常驻 < 40MB |
| 兜底 | `RimeService` 强制失败时，`PinyinEngine` 接管出词 |

### 8.3 兜底不变量：任何字母输入都必须出汉字

这是用户反复反馈的核心痛点 —— **随手乱按五个字母（`qwert`/`zxcvb`），面板里
一个汉字都没有，只剩一串英文**。根因有两处，已在自研引擎里堵死：

1. **`u`/`i`/`v` 开头无拼音键**：拼音里音节起头的 u/i/ü 写作 `wu`/`yi`/`yu`，
   词库没有 `u`/`i`/`v` 开头的键，于是 `u`、`i`、`v`、`vyrcp` 这类全查空。
   修法：兜底时把首字母按规范拼写再查一次（`LEAD` / `leadMap`）。
2. **`n<=2` 快路径提前返回**：1~2 字母走「短输入补全表」后直接 return，
   兜底层根本没机会跑，导致单字母 `u`/`i`、双字母 `ik`/`ul`/`vz` 全空。
   修法：快路径末尾也接一次兜底。

兜底策略 = **退到最长能出字的前缀**：从长到短砍尾巴，哪一段前缀查得出候选就用
它顶上，罚 `FB_PEN × 砍掉的长度`，保证它永远排在正常候选之后、只在「真没词」时露头。
两端口径一致：`tools/probe_dict.py`（参考端，`_fallback`）与
`Sources/Keyboard/PinyinEngine.swift`（真机端，`fallback`）。

**回归保证**：`python tools/probe_dict.py --fuzz` 穷举全部 1 字母、2 字母
（26 + 676）+ 3000 条随机 3~8 字母串，**「无汉字候选」必须为 0 条**。
改动引擎后先跑这条，绿了再谈其它。

---

## 9. 与现有代码的差异总览

| 项 | 现状 v0.3.5 | 目标 |
|---|---|---|
| 拼音内核 | 自研 `PinyinEngine.swift`（词图 + 字级 bigram + Beam） | librime（BSD）为主，自研兜底 |
| 候选生成 | 自研解码器 | librime 出基础候选 → Ranker 重排 |
| 配置交接 | 剪贴板整包 `ConfigSync` | 不变（付费后可切 App Group） |
| 布局 | 全局参数 `KBConfig` | schema v2：全局 + 每键覆盖 |
| Qwen | 无 | 宿主 App 离线智能回复，默认关 |
| 许可 | pypinyin/jieba（MIT） | + librime（BSD-3）+ 词库（待核） |

> **不改的**：剪贴板、自定义短语、本地 Qwen（默认关）、默认不上传任何输入文本、证书固定、登录/心跳体系。
