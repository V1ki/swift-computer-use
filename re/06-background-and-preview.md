# 06 — 后台输入与系统共享预览：实测边界及改造方案

调查时间：2026-10-29 09:31–09:42 Asia/Shanghai；macOS 27.2 (26B123)、arm64、Swift 6.4。复用 [04](<04-engine-internals.md>) 与 [05](<05-ax-less-apps.md>)，不重做既有冷态 AX / 原引擎反汇编实验。

## 0. 三个核心结论

1. **系统共享预览的公开接入点是 `SCStream.startCapture()`，不是自绘 NSPanel，也不是必须 `SCContentSharingPicker.present()`。** 单窗口 `SCContentFilter(desktopIndependentWindow:)` + 2 fps 持续 12 秒，实测 25 个 sample 回调；ControlCenter 收到 `streamDidStart`，`contentSharing` 流数增加到 7，停止后回到 6。这已验证进入系统共享管理。**本轮未直接肉眼/截图确认紫色像素、展开面板中的预览和停止按钮**：现存其他共享流、ControlCenter AX 仅暴露根节点，不能拿“没读到按钮”判定没出现。
2. **后台语义 AX 与 PID 键盘可用，但 PID 点击不等于后台点击可用。** Chrome 在前台时，TextEdit scratch 的 AXValue、AXSelectedTextRange、Unicode `postToPid`、格式 checkbox AXPress 均读回成功，前台不变；裸全局坐标 PID 点击没产生预期改变。微信通讯录 AXPress 返回成功但 AX 树不变；PID 坐标点击同样不变。不能回报静默成功，也不能直接宣称公开 API 对所有 App 均不可实现。
3. **系统共享 UI 与原版其他预览应分开。** 原版有 SCStream/CaptureStream，同时确实有 RemoteHostedPIPContentPublisher / WindowRenderer 与 record/replay NSStatusItem。系统面板可依赖系统复现，但“原版完全没有自绘/托管预览”不成立。普通 AX+postToPid 没有实现原版 synthetic focus；不能把“进程未真正激活”当成“已假装激活”。

标记：**[实测]** 本轮运行；**[静态]** 既有 nm/strings 与 plist；**[官方]** Apple 文档；**[建议]** 改造设计，不是完成实现。

## 1. 安全、权限与实验局限

- 仅写本报告和 [background 材料目录](<raw/engine/background/>)；没有修改 Sources/js/docs/README，没有 git、终止进程、发送消息、调用现有服务执行动作。
- [预检](<raw/engine/background/preflight.jsonl>)：独立 Swift 进程 `AXIsProcessTrusted=true`、`CGPreflightScreenCaptureAccess=true`。未调用请求权限 API，未出现权限弹窗。**授权给 SwiftCUA 不代表任意新 helper 都有授权**；本轮运行上下文实际已有权限。
- 捕获目标为探针自建 480×300 的无隐私 NSWindow（用户允许的可关闭测试窗口），非微信，输出图片未落盘。持续流只启动一次，约 12.2 秒，之后明确 `stopCapture()`。
- TextEdit 原有 2 个窗口；只通过新旧 AXWindow 集合差定位本轮新建的未保存 scratch，写入固定测试文字；最后关闭且丢弃本轮文档，恢复到 2 个窗口。**未读出或写入原有文档内容。**
- 微信仅操作已知“通讯录”和返回聊天的侧栏按钮；没有输入文字、发送、删除或点击联系人。只保存角色计数；后续加强版把 AX 内容在内存做带随机盐 SHA-256，盐不落盘，正文不入库。
- 桌面并非独占：捕获期间前台为 Codex；部分时段有物理鼠标连续移动；第二轮微信前台恢复到该轮开始时的钉钉会议。测量必须看每条实际 before/after，而不是实验计划。**不将外部活动归因于 probe；也不把污染样本算成“光标不动成功”。**
- 稍后 TextEdit 被外部关闭，显式 windowID 字段点击扩展试验退出 4，未执行；没有重新启动它或争抢桌面。Finder / SwiftCUA 输入、scroll、fake activation 内部状态、手动点击系统“停止共享”未测。

## 2. A：系统“正在共享”预览

### 2.1 可复现最小 API 与命令

完整 [probe.swift](<raw/engine/background/probe.swift>) 同时包含 screenshot / stream 模式。关键代码：

```swift
_ = NSApplication.shared
_ = NSScreen.screens
// window 从 SCShareableContent.windows 按精确 windowID 取出
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.width = 480
config.height = 300
config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
config.queueDepth = 3
config.showsCursor = false
config.capturesAudio = false
let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .main)
try await stream.startCapture()
try await Task.sleep(nanoseconds: 12_000_000_000)
try await stream.stopCapture()
```

主线程服务 runloop，避免 NSWorkspace 的异步前台缓存与 SCK 初始化问题；不调用 activate，不改变物理指针。实际 probe 用循环采样代替单次 sleep。运行：

```sh
swift re/raw/engine/background/probe.swift preflight
swift re/raw/engine/background/probe.swift screenshot
swift re/raw/engine/background/probe.swift stream
```

`preflight` 无权限则停止，不要自行添加权限提示。独立 shell helper 的共享身份**不一定是 helper 文件名**：本轮系统归因到 `com.googlecode.iterm2`。生产流应由真正 SwiftCUA app 身份内的服务持有，不要靠改文案冒充 ChatGPT。

### 2.2 日志证据与一次截图对照

[stream.jsonl](<raw/engine/background/stream.jsonl>)：09:33:10 开始，09:33:22 停止，25 个 sample 回调（只是回调数，未把 idle/complete 状态分别统计，不能声称 25 张独立新画面）。[screenshot.jsonl](<raw/engine/background/screenshot.jsonl>)：09:33:03 成功一次 480×300 图像。

精简 [capture-key.log](<raw/engine/background/capture-key.log>) 每行前缀为 [完整日志](<raw/engine/background/capture-system.log>) 行号：

| 时间 | 证据 | 解读 |
|---|---|---|
| 09:33:03.433 | `updateScreenCaptureDidStart ... hasStarted=1` | 一次截图也开始隐私归因 |
| 09:33:03.474 | `outputType=0 ... hasSCKSystemRecordingEntitlement=0` | screenshot 路径 |
| 09:33:03.491 | ControlCenter `sensor-indicators`: 增加 `[scr] iTerm2` | **不能说截图绝不触发任何指示** |
| 09:33:03.507 / .538 | `hasStarted=0`；归因移除 iTerm2 | 短暂状态，并非持续共享预览 |
| 09:33:09.992 | `outputType=1 ... hasSCKSystemRecordingEntitlement=0` | stream 路径 |
| 09:33:10.059 | replayd / ControlCenter `streamDidStartWithConfiguration:contentFilter:` | 系统收到持续流注册 |
| 09:33:10.069 | `com.apple.controlcenter:contentSharing` → count 7 | 新增系统共享条目 |
| 09:33:22.273 / .280 | `streamDidStop...`；count 6 | 本 probe 停止并撤销共享条目 |

在 screenshot 时间段**没有** `contentSharing` count 增加或 `streamDidStart`。这支持“一次截图不能维持可停止的持续共享面板”，但不支持“截图从不亮隐私指示器”。原本还有 ChatGPT 共享与系统设置麦克风归因，紫色图标有无本身不是有效 A/B 指标；禁止为了干净基线去停用户现有共享。

复现本轮日志（时间参数为本机 Asia/Shanghai）：

```sh
/usr/bin/log show --start '2026-10-29 09:33:00' --end '2026-10-29 09:33:25' \
  --style compact --info --debug \
  --predicate '(subsystem CONTAINS[c] "screencapture" OR subsystem CONTAINS[c] "screenshar" OR process == "ControlCenter" OR process == "replayd")'
```

自动化建议窄谓词：

```text
(process == "ControlCenter" AND subsystem == "com.apple.controlcenter"
 AND category == "contentSharing")
OR (process == "replayd" AND
 (eventMessage CONTAINS "streamDidStart" OR eventMessage CONTAINS "streamDidStop"))
```

日志是**可复现实验佐证，不是稳定产品 API**：私有字段可变、统一日志可能丢失/隐去 ID、同时别的流开关会污染 count。必须用本进程 start/stop 时间与帧回调交叉核对；本轮没有声称仅凭 count 精确恢复系统的 windowID→stream 映射。

### 2.3 紫图标、面板、picker、plist 与 entitlement

[Apple WWDC23 “What’s new in ScreenCaptureKit”](https://developer.apple.com/videos/play/wwdc2023/10136/) 介绍系统 Video menu / sharing controls 与 stream 集成，包括内容预览、停止/变更共享及 `SCContentSharingPicker`。据此与本轮 ControlCenter 注册证据：

- 持续 `SCStream` 是这条公开、可落地路径的核心；**不需要通过 picker 才注册**，本 probe 没有调用 picker，系统仍增加 contentSharing 流。
- `SCContentSharingPicker.shared.isActive = true`、`present(...)` 用于系统选择/变更共享对象、按用户选择得到 filter；其 observer 更新时应 `stream.updateContentFilter(...)`。它不是输入焦点管理，也不是用来绘制“正在共享”小窗的替代 NSWindow。
- 不能泛化为“所有系统共享 UI 都只能 SCStream 触发”；其他系统/旧捕获路径也可能有指示。**要复现本题单窗口持续预览，选 SCStream，而不是反复截图。**
- `startCapture` 使系统条目可用，**不保证自动展开一个持久浮窗**。用户通常通过菜单栏打开系统面板；不建议模拟点击强开面板，更不要自绘一个假的系统停止按钮。
- 原版 [plist](<raw/engine/background/original-plist.log>) 的 `LSUIElement=true`，说明 agent app 与该机制并不冲突。probe 是 accessory 策略，不是 LSUIElement A/B；不能宣称不同 plist 配置完全等价。
- 原版 [entitlements](<raw/engine/background/original-entitlements.log>) 没有特殊 ScreenCaptureKit system-recording entitlement，本轮日志也明确为 0。普通已授权 SCK 足以注册共享条目；无需为了“让图标显示”申请私有 entitlement。bundle identity、签名、TCC/responsible process 影响归因和授权，`CFBundleDisplayName` 只属于名字来源之一，不是触发开关。
- [controlcenter.jsonl](<raw/engine/background/controlcenter.jsonl>) 只读到 AXApplication，无窗口/菜单子树；所以**紫色图标颜色、预览图内容、“停止共享”按钮存在/点击效果留作人工验收**，不是本轮已完成的视觉证据。

## 3. B：后台输入实测矩阵

工具：[input.swift](<raw/engine/background/input.swift>)。鼠标使用 `CGEvent(mouseEventSource:nil, mouseType:..., mouseCursorPosition:global, ...)` + `postToPid(pid)`；键盘 keyCode=0、UTF-16 `keyboardSetUnicodeString`，down/up 均投目标 PID。AXPosition 已是全局左上坐标，点击中心等价于“窗口原点 + 控件局部中心”，**不能再叠加一次窗口原点或翻转 Y**。本轮未设置私有 window-local 字段，也未伪造激活事件。

[TextEdit 结果](<raw/engine/background/textedit.jsonl>) 与 [微信结果](<raw/engine/background/wechat.jsonl>)：

| 后台目标 / 操作 | 结果与 API 状态 | 观察耗时 | 前台 | 物理光标 |
|---|---|---:|---|---|
| TextEdit `AXValue` 写固定 scratch 字符串 | 0；全文读回一致 | 365 ms | Chrome 保持 | 精确不变 |
| TextEdit `AXSelectedTextRange` → (0,0) | 0；读回 location=0 | 364 ms | Chrome 保持 | 精确不变 |
| TextEdit Unicode `postToPid` | `后台✓` 插入开头；selection=3 | 404 ms | Chrome 保持 | 精确不变 |
| TextEdit 裸 PID click 文本中心 | 文字/selection 均未变；未证明点击成功 | 402 ms | Chrome 保持 | 精确不变 |
| TextEdit 格式 checkbox `AXPress` | 0；value 0→1 | 454 ms | Chrome 保持 | 精确不变 |
| TextEdit 裸 PID click 同格式 checkbox | value 仍 1，未翻转 | 405 ms | Chrome 保持 | 有外部移动，污染 |
| 微信 通讯录 `AXPress` | 0，但节点/角色不变 | 356 ms | Chrome 保持 | 首轮精确不变 |
| 微信 通讯录裸 PID click | 节点/角色不变 | 424 ms | Chrome 保持 | 首轮精确不变 |
| Finder / SwiftCUA / scroll / 显式 windowID click | 未测；不列为失败或成功 | — | — | — |

耗时包含固定 350 ms settle、键盘/鼠标 down/up 的各 20 ms wait 与 AX IPC；**不是响应延迟基准或 P95**。postToPid 是 void，没有“点击成功返回码”；日志 `apiCode=0` 对此只是 probe 提交完毕，不能当成 OS 确认。

TextEdit 每条 `targetFrontmost=false`、`targetFocusedWindow=true`：后台应用仍可有应用内部 focusedWindow；这不表示系统 key window，更不是 synthetic activation 的证明。未运行激活伪造、全局 event tap、cursor warp API。

### 微信失败表现与证据强度

首轮 114 节点与角色数前后相同；第二轮 [wechat-hash.jsonl](<raw/engine/background/wechat-hash.jsonl>) 为 117 节点，`AXPress` 和 PID 点击后**加盐全文结构哈希均与该轮基线相同**。结论是“AX 状态没有可观测切页”，不是 `AXError` 失败，实际 AXPress=0。没有窗口截图作视觉复核，因此严格表述为**未证实切页/本次语义后置条件失败**。第二轮用户活动明显，光标指标不采信。由于同时存在第二个微信窗口/其他状态差异，不能泛化为所有微信窗口、所有版本永远失败。

工具的初版 Int/Int32 类型错误已修复并保留 [编译失败记录](<raw/engine/background/textedit.stderr>)；当前四个 Swift 文件均 typecheck 通过。扩展 `.mouseEventWindowUnderMousePointer` 和 `.mouseEventWindowUnderMousePointerThatCanHandleThisEvent` 的代码已放入 TextEdit 分支，**最后试跑因为 TextEdit 不在运行退出 4，未完成动态验证**，见 [运行记录](<raw/engine/background/run-status.log>)。

## 4. C：合成焦点的可实现性与原版证据边界

### 4.1 公开 API 可以/不可以保证什么

- **可以做**：`AXUIElementPerformAction`、`AXUIElementSetAttributeValue`、`AXSelectedTextRange`；已授权的 `CGEvent.postToPid`；不调用 `NSRunningApplication.activate` / `AXRaise`；在自己控制的预览图上画虚拟指针，不触碰物理指针。
- **不能保证**：任意 App 后台接受鼠标；目标的 first responder/key window 任意可控；跨窗口命中正确；菜单/模态对话框/IME 在不激活条件下工作；阻止目标或系统在动作中自行抢前台。
- `CGEventTapCreate`、runloop source、listen-only 观察是**公开 API**，不能笼统称“event tap 必须私有”。但一般 session event tap 不是给另一个进程补造完整 AppKit/window-server 激活状态的公开高层接口；拦截/丢弃鼠标键盘也不等于阻止所有 NSWorkspace/window ordering 激活。
- 目标应用“相信自己 active/key”而系统仍保持 Chrome 的组合，没有通用公开保证。原版内部 focus/WindowServer SPI 应作为独立兼容性研发，而非 `postToPid` 两行代码就已复现。
- `WindowServerSPI.setWindowLocation(CGEventRef, CGPoint)` 是**事件窗口局部坐标**，不是搬动窗口；复用既有结论，不重复验证。

### 4.2 新增静态搜索证据

集中摘录：[static-evidence.txt](<raw/engine/background/static-evidence.txt>)，保留原始来源文件名和行号，完整来源为 [nm-demangled.txt](<raw/engine/nm-demangled.txt>) / [strings.txt](<raw/engine/strings.txt>)。

| 出处 / 地址 | 证据 | 允许的结论 |
|---|---|---|
| nm 465–491 | `_OBJC_CLASS_$_SCStream`、configuration、frameInfo | 确实链接持续捕获类型，不只是截图 |
| nm 6357 / `0x10005fae0` | `ComputerUse.CaptureStream stream:didOutputSampleBuffer:ofType:` | 有 SCK 输出接收实现 |
| nm 6358 / `0x10005fb70` | `CaptureStream stream:didStopWithError:` | 有流停止错误处理 |
| strings `0x12f2527` / `0x12f267d` | `startCaptureWithCompletionHandler:` / `stopCaptureWithCompletionHandler:` | 有启动/停止 selector；字符串本身不是调用链证明 |
| nm 3106–3108 | `applicationBelievesItHasFocus`、`applicationIsActive`、`applicationBelievesItIsActive` | 原实现有意识地区分真实与合成焦点 |
| nm 4939 等 | `SyntheticAppFocusEnforcer.clickEventTap` 等 | 与已有 focus enforcer 结论一致 |
| nm 16302 / `0x1001f4794` | `RemoteHostedPIPContentPublisher.publishWindowStream(threadID:turnID:windowID:)` | 另一套按窗口/任务发布预览流的机制存在 |
| nm 166667–166668 | `RemoteHostedPIPWindowRenderer` | 存在托管窗口画面渲染类；不能说全无自绘/托管预览 |
| nm 170241–170243 | `RecordAndReplayRecordingControlsController.statusItem/View/Menu` | 有 record/replay 状态项，不能把 NSStatusItem 搜中即等同题述系统面板 |
| strings `0x121826e` | `So12NSStatusItemC` | ObjC 类型名字符串；不是独立“系统共享图标创建”证据 |

`sharingIndicator` / `SCContentSharingPicker` 在本次 nm/strings 搜索中无命中，不证明动态查找/系统间接路径不存在。大量 Sharing/preview 是 analytics/protobuf，不应误判为渲染代码。`SkyshotCapture` 与 `Package_Appshot.bundle` 主要说明截图/资源分层，不能单凭名字断言系统小窗由它画。

**归纳**：题述“正在共享 + 停止共享”的系统 UI 可由 macOS 创建；原版也有其他 PIP。现有静态证据不能把截图中某一实例精确归因到全部内部路径，不能声称“完全依赖系统 UI”或恢复了完整 focus enforcer 实现。

## 5. D：SwiftCUA 方法级改造建议

源码在研究期间有并行编辑，以下针对方法/职责，不将阅读时某行视为最终 commit。只读了 [SkyEngine.swift](<../Sources/CUAEngine/SkyEngine.swift>)、[InputSynthesis.swift](<../Sources/CUAEngine/InputSynthesis.swift>)、[ScreenCapture.swift](<../Sources/CUAEngine/ScreenCapture.swift>)，没有修改它们。

### 5.1 动作路线

1. `SkyEngine.prepareTarget`：默认 background policy，不 activate、不 AXRaise；校验 PID/window/revision。`launchApp` 的 `NSWorkspace.OpenConfiguration.activates` 也应与 policy 一致，避免冷启动默认抢前台。
2. `accessibilitySnapshot`：先读窗口内容、有限 manual/enhanced enablement、轮询就绪（复用 [05](<05-ax-less-apps.md>)），不把 AXWindows>0 当就绪；仅在明确 opt-in 且 background-only 能力不足时进入一次性 `ActivationLease`。
3. `performClick`：有效 AX element 且支持 `AXPress` 时优先语义动作，然后读取预期 value/selected/page 状态；API=0 不足以成功。无 AX/OCR 坐标候选通过 `InputSynthesis.click(..., pid, windowID)` 走已验证 PID 路由，**本轮裸 PID 鼠标失败，默认不能承诺可用**。能力不足返回 `requiresForeground` / `backgroundInputUnsupported`，不要在用户不知道的情况下改为全局 HID 点击。
4. `InputSynthesis.post/key/text/mouse/scroll/drag`：显式 `InputTarget`，不允许漏传 PID 意外退化为 `.cghidEventTap`。坐标记录全局/窗口局部/截图 scale 版本。公开 window-under-pointer 字段只应作为可测兼容路径，本轮还没证实能修复 TextEdit。
5. `performTypeText/setValue/selectText`：已知可写文本控件优先 AX；**输入语义与全量替换不同**，不能直接把用户原文覆盖来模拟插入。读 selection，以 UTF-16 索引执行 replace/selection，失败再用经验证 PID Unicode。TextEdit 后台 Unicode 已证实，但不能扩展到 Secure Input、IME、所有 Electron/微信。
6. 需要激活时：授权范围明确为一个 app/window、一次 warm-up/一次动作；保存原 PID，完成后仅在仍是本次激活持有状态、用户未接管时恢复，避免把用户后来切换的 app 抢走。如果每个动作都需要 key window，这不是“一次激活后永远后台”；必须报告真实限制。
7. 通过 `NSWorkspace.didActivateApplicationNotification`、listen-only event tap 或保守轮询监视接管；检测到外部鼠标/焦点变更停止输入而非与用户竞争。回报 postcondition，不把盲目 fallback 堆叠成成功。

### 5.2 预览服务

新增/完善独立 `WindowStream` / `PreviewSession` actor：

```text
begin(taskID, pid, windowID)
  → 权限预检 + identity/窗口验证
  → SCContentFilter(desktopIndependentWindow:)
  → SCStream + addStreamOutput + startCapture
noteInteraction(taskID) → 延后 idle deadline
latestFrame(windowID, maxAge) → 有界最新完整帧，不累计帧队列
end(taskID) / idle / cancel / targetGone → await stopCapture + 释放缓冲
stream(_:didStopWithError:) → 标为用户/系统停止，取消相关任务，不自动重开
```

- 任务期间开始，结束立即停止；idle 可设 5–10 秒。研究/测试给硬上限 20 秒。生产长期任务持续可见需产品明确同意，不能为了“看起来在工作”空跑无限共享。
- 1–2 fps、适度缩小画面、`queueDepth=3`、不采音频、`showsCursor=false`、最多每目标一个 stream；避免每帧 JPEG 编码/磁盘写入。帧率是调度上限，不是每秒必须变化。
- 低帧率仍有 WindowServer/GPU/内存/系统预览开销；本轮没测 CPU，不给虚构百分比。需要用 Instruments/进程采样对照无流、低帧率流、频繁 screenshot 三组。
- 系统窗口预览本身会公开被共享的内容；只分享授权目标，不把全屏 filter 当方便替代；不静默重新开启被用户停止的流。
- 系统停止的 delegate 回调应与任务取消关联，明确区分正常主动 stop、用户撤销、窗口消失、TCC 错误；具体 NSError code 与系统停止按钮交互还需人工回归。

## 6. 验收脚本与未解项

### 6.1 已保存的脚本

- [probe.swift](<raw/engine/background/probe.swift>)：权限、单截图/12 秒持续流、自建无隐私窗口。
- [input.swift](<raw/engine/background/input.swift>)：TextEdit scratch、微信限定侧栏、before/after 状态、AX 读回；**包含 setup/cleanup 的显式激活，不要把整个脚本当“不激活验收”运行**。
- [controlcenter.swift](<raw/engine/background/controlcenter.swift>)：系统 AX 元数据诊断，不能保证读取受保护的系统预览。
- [verify.swift](<raw/engine/background/verify.swift>)：只读包裹命令，监听 activation notification，同时每 10 ms 检查 frontPID / CGEvent.location。示例（先人工准备无害目标）：

```sh
swift re/raw/engine/background/verify.swift /absolute/path/to/background-action arg1 arg2
```

被包裹命令必须自己验证业务后置条件，失败退出非零。验收联合条件：`commandExit==0 && frontChanged==false && activationEvents==0 && cursorChanged==false`。它既检查过程也检查结束，能拒绝“抢前台再切回来”伪无扰动；短于采样间隔的指针往返仍可能漏掉，严格版本应用 listen-only CGEventTap 补充事件来源/自定义 tag（不拦截用户输入）。

`/usr/bin/true` smoke 的 [verify-smoke.jsonl](<raw/engine/background/verify-smoke.jsonl>) 为 commandExit=0、frontChanged=false、**cursorChanged=true / observedPass=false**，因此脚本退出 1：是外部鼠标活动导致的有效拒绝，不是命令成功就错误报通过。不能拿这轮作严格无扰动成功验收。全部 probe typecheck=0，见 [run-status.log](<raw/engine/background/run-status.log>)。

### 6.2 最低验收表

1. TextEdit 新 scratch：AX 写值/selection/Unicode 读回预期；Chrome PID 全程不变、cursor 不变；结束不保留 scratch、不动旧文档。
2. 裸 PID mouse / windowID 字段 / AXPress 分开测试；checkbox 必须确实翻转，不能以 AXError=0/事件发出作为通过。
3. 微信只读侧栏：目标切页的明确 AX selection/value 或无隐私的视觉判断；若无变化返回不支持，不升级为发送/输入试验。
4. 单窗口 stream：start 成功+完整帧+系统 contentSharing 注册；stop 后取消本条流，不终止其他人的流。人工确认紫色图标、单窗口预览、停止按钮，并点击停止后验证引擎不会自启恢复。
5. 一次截图允许短暂 sensor indicator，但不得把它当成持续共享预览；多流并存时按自身会话判断，不用“图标消失”作为停止标准。
6. 冷态懒 AX、同 app 多窗口、隐藏/最小化、不同 Space、key-window-required、modal、Secure Input、用户接管分别降级；公共模式不得声称覆盖所有应用。

### 6.3 未解与结论等级

**已完成**：SCK 单窗口持续 12 秒与一次截图运行；系统 start/stop/contentSharing 日志；TextEdit 四项有效后台操作；裸 PID mouse 未成功样本；微信返回0但AX状态未变；原版符号/身份补充；方法级设计与验收监测器。

**未完成**：直接视觉确认紫色及面板/停止按钮；系统停止回调实测；explicit windowID mouse 的动态测试；Finder/SwiftCUA/scroll；应用内部是否“假装激活”的可观测证明；CPU 基准；无外部活动条件下整套严格重复实验。这些留空而不以猜测补齐。原目标包含视觉观察，因此本报告是**可落地且有明确缺口的调查结果，不是宣称所有验收项已完成**。
