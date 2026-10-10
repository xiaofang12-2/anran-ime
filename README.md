# 黯然输入法（iOS）

iOS 第三方输入法。26 键拼音 + 思想库 + 剪贴板 + 自定义短语。

> 名字、Bundle ID（`com.anran.ime`）都是占位的，定了正式名一次替换即可。

## 为什么本地编不了

iOS 的编译、签名、真机安装必须走 macOS 的 Xcode。开发机是 Windows，所以：

- **源码在这里写**
- **编译交给云 Mac**（GitHub Actions 的 `macos-latest` runner，配置见 `.github/workflows/ios.yml`）
- **签名交给手机那头的 Sideloadly**（免费 Apple ID 自签，7 天续一次）

## 目录结构

```
project.yml                  XcodeGen 工程定义（改这个，不要手改 .xcodeproj）
Sources/
  Shared/SharedStore.swift   主 app 与键盘共用的数据层（App Group）
  HostApp/                   主 app：自检 + 启用引导（阶段 3 加思想库/剪贴板/短语面板）
  Keyboard/                  键盘扩展：输入法本体
Support/
  HostApp/Info.plist         主 app 注册信息
  HostApp/HostApp.entitlements
  Keyboard/Info.plist        键盘注册信息（NSExtension 配置在这）
  Keyboard/Keyboard.entitlements
.github/workflows/ios.yml    云 Mac 编译 -> 出未签名 ipa
```

## 阶段 0 验收（当前阶段）

目标：**证明整条链路通**，功能只有「能弹出 + 能敲英文字母」。

1. 云端 CI 跑通，产出 `AnRanIME-unsigned.ipa`
2. 用 Sideloadly 装进 iPhone
3. 设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 选「黯然输入法」
4. 点进「黯然输入法」→ 打开「完全访问」
5. 任意输入框能弹出键盘、能敲英文字母
6. **主 app 打开，看「共享容器已连通」还是「共享容器不可用」**

第 6 条是关键：免费 Apple ID 属于 Personal Team，App Groups 未必可用。
不通就走回退方案（主 app 上传到自建服务器，键盘开完全访问后拉取）。

## 关键约束（写代码前先看）

- **键盘扩展内存只有 30~60MB**，超了被系统静默杀掉，键盘直接消失且无崩溃日志。词库必须按需加载，不能全量塞内存
- **默认沙盒禁网**，且和主 app 隔离。要读自己的数据必须让用户开「完全访问」
- **读不到其他 app 的内容**，所以 Windows 版那套截屏 OCR 自动怼在 iOS 上做不了
- **剪贴板能读但会弹系统确认**，挡不掉
- **键盘必须用户手动在设置里启用**，这步苹果不给自动化

## 阶段规划

| 阶段 | 内容 | 验收 |
|---|---|---|
| 0 | 工程骨架 + 云 CI + 空键盘 | 装进手机能弹出能敲英文，App Group 自检出结果 |
| 1 | librime 交叉编译 + 26 键拼音 | 打字能出中文，候选栏能选字 |
| 2 | 思想库 | 顶部横栏点开弹输入框，内容进当前 app |
| 3 | 剪贴板 + 自定义短语 + 主 app 三个面板 | — |
| 4 | 9 键 + 中英混输 + 学习习惯调优 | — |

## 授权

拼音引擎用 [librime](https://github.com/rime/librime)（BSD-3-Clause，可闭源商用）。
**不要直接搬仓输入法等 GPL 系开源键盘的代码**，会把本项目也绑成开源。
