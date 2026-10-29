# 验证记录

本文记录 SwiftCUA 在本机（macOS 27.2 / 26B123, arm64, Xcode 27.1, Swift 6.4, Node 24.13.1）
上的实测结果，用于区分「已验证」与「需要用户授权后才能验证」的部分。

## 1. 自动化测试

| 套件 | 命令 | 结果 |
|---|---|---|
| Swift 全包 | `swift build` | ✅ 0 warning / 0 error |
| CUACore | `swift test --filter CUACoreTests` | ✅ 2 tests |
| CUAEngine | `swift test --filter CUAEngineTests` | ✅ 10 tests（纯函数：AX 文本格式、键位解析、坐标/缩放、索引过期语义） |
| CUAService | `swift test --filter CUAServiceTests` | ✅ 13 tests（握手/授权/权限门/帧分片/超大帧/socket 权限/单实例/路径穿越/TTL） |
| CUAClient | `swift test --filter CUAClientTests` | ✅ 15 tests（socket、超时、自动握手、session 注入、MCP schema/initialize/转发） |
| JS 桥 | `cd js && node --test test/` | ✅ 21 tests（分帧、粘包、超时、sky 方法、MCP、沙箱逃逸边界） |
| 端到端冒烟 | `./scripts/smoke.sh` | ✅ 9 passed / 0 failed |
| 合计 | — | **40 个 Swift 测试 + 21 个 JS 测试全绿** |

`scripts/smoke.sh` 覆盖：socket 建立、ping、list_apps、list_windows、doctor、会话 TOML 落盘、
未知方法拒绝、权限缺失时的错误映射、MCP `initialize` + 14 工具 `tools/list`。

## 2. 协议实测（安装版服务）

```
$ cua ping
Service: 0.1.0
API: SwiftCUA-IPC-1
Platform: macOS
Screen Recording: missing
Accessibility: missing

$ cua apps | wc -l
327
```

ping 结果（`cua call ping` / JS `sky.ping()`）：

```json
{"sessionId":"…","platform":"macOS","serverVersion":"0.1.0","apiVersion":"SwiftCUA-IPC-1",
 "features":["ping","getPermissions","listApps","listWindows","getAppState","click","pressKey",
             "typeText","scroll","setValue","drag","paste","selectText","performSecondaryAction",
             "captureScreenshot","endSession"],
 "permissions":{"accessibility":false,"screenRecording":false}}
```

会话文件（`~/Library/Application Support/SwiftCUA/sessions/<uuid>.toml`，权限 0600）：

```toml
[apps]
allowed = ["com.google.Chrome"]
```

## 3. 引擎实测（开发版服务，TCC 从终端继承）

安装版服务由 `launchd` 拉起，必须由用户在系统设置里单独授权；开发版从终端启动时继承了终端的
Accessibility / Screen Recording，因此可以在这里验证真实引擎行为。

```
$ cua state --app com.google.Chrome --no-screenshot
App: Google Chrome (com.google.Chrome)
Window: "V1ki/swift-computer-use: A from-scratch Swift reimplementation of macOS computer…"; elements=1233; truncated=false
[0] window "…" actions=[AXRaise] frame=(-1048.0,-1410.0,2560.0,1410.0)
  [1] group "…" {enabled} frame=(-1048.0,-1410.0,2560.0,1410.0)
    [2] group {enabled} actions=[AXShowMenu] frame=(-1048.0,-1410.0,2560.0,1410.0)
    …
```

- AX 树：**1233 个元素**，窗口标题/坐标正确，元素索引连续，`focusedElement` 正确解析。
- `--query Reload` 过滤后保留匹配节点及其祖先：**8 行**。
- `getAppState.windows` 过滤掉 1×1 helper 窗口后剩 **5** 个真实窗口。
- 截图：`cua screenshot --app com.google.Chrome` → **JPEG 2560×1410**（Retina 2×，points 元数据 2560×1410）。
- 元素索引过期/权限缺失/窗口不存在等错误码路径符合 `docs/PROTOCOL.md`。

## 4. 安装版服务

```
$ launchctl print gui/501/dev.v1ki.swiftcua.service
state = running
program = ~/Applications/SwiftCUA.app/Contents/MacOS/CUAService

$ ls -l ~/Library/Application\ Support/SwiftCUA/IPC/
srw-------  computeruse.sock

$ cua doctor
[PASS] socket exists
[PASS] connectivity: Unix socket connected
[PASS] ping: JSON-RPC response received
[PASS] API version: SwiftCUA-IPC-1
[FAIL] Screen Recording
[FAIL] Accessibility
```

签名：`Apple Development: …`，`codesign --verify --deep --strict` 通过；bundle id `dev.v1ki.swiftcua`。

## 5. 需要用户授权的部分

以下行为在自动化验证中**主动未执行**（会抢占鼠标/键盘或弹系统授权框），留待用户授权后自行验证：

1. 在「系统设置 → 隐私与安全性」中给 `~/Applications/SwiftCUA.app` 授予
   **屏幕录制** 与 **辅助功能**，然后 `launchctl kickstart -k gui/$(id -u)/dev.v1ki.swiftcua.service`。
2. 真实输入注入（click / type / key / drag / paste）——会移动光标、改变前台窗口。
3. 特殊应用（Electron、游戏、Java 应用）的 AX 树质量与键盘选择回退路径。

## 6. 已知限制

- 公开 AX API 不暴露 `CGWindowID`，窗口映射使用 AX frame ↔ 窗口服务器 bounds 匹配（容差 3pt）。
- 原服务支持锁屏后操作（授权插件），SwiftCUA 刻意不实现。
- `disableDiff` 被接受但始终返回全量树（原服务默认返回 diff）。
- 输入注入会激活目标 App 并使用全局 `CGEvent`；原服务使用 `CGEventPostToPid` 等私有路径实现更隐蔽的后台注入。

## 7. 真实应用实测：微信（`com.tencent.xinWeChat`）

用户在系统设置中授权后，安装版服务 `cua doctor` 六项全部 PASS。用微信做第一次真实桌面操作：

**发现的限制**：微信把窗口藏在无障碍树之外 ——
`kAXWindowsAttribute` 返回 0 个窗口，`kAXMainWindowAttribute` / `kAXFocusedWindowAttribute` 均为 nil，
`kAXChildrenAttribute` 只有 2 个 `AXMenuBar`。因此 `cua state` 只能拿到 197 个节点（菜单栏），
没有聊天窗口的任何可访问元素。

**降级路径**：截图 + 窗口相对坐标。

```bash
cua screenshot --window 410 --out /tmp/wechat-main.jpg      # 3024×1898 px = 1512×949 pt @2x
cua click --app com.tencent.xinWeChat --window 410 --x 190 --y 31
cua type  --app com.tencent.xinWeChat --text "SwiftCUA computer use test"
cua screenshot --window 410 --out /tmp/wechat-typed.jpg    # 搜索框内文字确认
cua press-key --app com.tencent.xinWeChat --key Escape      # 关闭搜索，恢复界面
```

结果：点击落在顶部搜索框，Unicode 输入正确（搜索框显示 `SwiftCUA computer use test`），
Esc 正常清除；聊天输入框未被触碰，**没有发送任何消息**。

启示：

1. 对 AX 树缺失的应用（微信、部分 Electron/CEF 应用、游戏），computer use 必须走「截图 → 视觉定位 → 坐标点击」。
   SwiftCUA 的 `capture_screenshot` + `click --x/--y` 已覆盖这条路径。
2. `click` 的坐标是**窗口内** points，跨 Retina/多显示器由引擎换算成全局坐标，截图返回的 `originX/originY` 可用于反推。
3. 这类应用上不要依赖 `elementIndex`，会返回 `elementIndexStale`/`elementNotFound`。

## 8. 微信类 App 实测：懒 AX 与像素回退

在用户授权后，用安装版服务对微信做了完整链路验证（微信是最典型的「懒 AX」应用）。

### 8.1 懒 AX：后台读取会触发一次性激活

```bash
open -a "Google Chrome"                       # 微信退到后台
cua state --app com.tencent.xinWeChat --no-screenshot
```

结果：引擎检测到 AX 根不是 `AXWindow`（只有 197 个菜单节点），自动激活微信并重抓，
得到 **90 行 / 89 节点**的完整树：`list "会话"`（每行一个 `staticText`）、`list "消息"`、
输入框 `textArea "…"`、`button "发送"`（输入框为空时是 `disabled`）。

> 研究结论见 [re/05](https://github.com/V1ki/swift-computer-use/blob/main/re/05-ax-less-apps.md)：
> 微信暖启动后即使退到后台 0.8/5/30s 仍能读树；最小化保留，隐藏后窗口枚举归零。
> 首次激活是**一次性**初始化成本，不是「必须一直前台」。

### 8.2 `AXPress` 不可靠 → 像素点击

微信侧边栏按钮（微信 / 通讯录 / 收藏）虽然暴露 `AXPress`，但调用后页面不切换。
`clickText` 因此改为**始终点击命中框中心**：

```bash
cua find-text  --app com.tencent.xinWeChat --text 通讯录
# 0  通讯录  ax  2,148 56×34
cua click-text --app com.tencent.xinWeChat --text 通讯录
# 页面切换：lists ["通讯录"] + 出现 新的朋友 / 群聊 标记
cua click-text --app com.tencent.xinWeChat --text 微信 --exact
# 切回：lists ["消息", "会话"]
```

### 8.3 OCR 路径闭环

`--ocr-only` 强制走视觉定位（微信侧边栏是纯图标，OCR 找不到「通讯录」；搜索框文字可以）：

```bash
cua find-text  --app com.tencent.xinWeChat --text 搜索 --ocr-only
# 0  • 搜索  ocr  81,22 40×13  windowId=410  conf=0.30
cua click-text --app com.tencent.xinWeChat --text 搜索 --ocr-only
# focusedElement: [64] 搜索  ← 焦点确实进到搜索框
cua type --app com.tencent.xinWeChat --text swiftcua-ocr
cua screenshot --window 410 --out /tmp/search-typed.jpg
cua find-text --app com.tencent.xinWeChat --text swiftcua --ocr-only
# 0  Swiftcua-ocr|  ocr  94,21 72×11   ← 截图 OCR 反查到刚输入的文字
cua press-key --app com.tencent.xinWeChat --key Escape   # 清理，输入框无草稿
```

### 8.4 过程中发现并修掉的两个真问题

1. **「最大窗口」静默替换**：微信当时存在第二个窗口 `微信 (窗口)`（1080×1890，分离窗口）。
   `screenshot --app` / 坐标点击按面积选窗口会选到它，导致 OCR 坐标落到另一个窗口，
   一次测试中把测试文字打进了另一个会话的输入框（发现后已用 `set-value ""` 清除，未发送）。
   修复：优先用 AX 主窗口 frame 反查窗口服务器条目；`CUATextMatch` 带 `windowId`，
   `clickText` 只用匹配所在窗口的坐标。
2. **OCR 默认忽略小字号**：Vision 的 `minimumTextHeight` 默认是图高的 1/32（2× 截图约 59px），
   11–13pt 的 UI 文字全部被丢弃。改为 `0.005` 后能识别工具栏/搜索框等小字。

### 8.5 结论：这类 App 的控制顺序

1. **AX 优先，但要区分「懒创建」和「没有」**：先读，根不是 AXWindow 就有限激活重抓；
   Electron 再尝试 `AXEnhancedUserInterface` / `AXManualAccessibility` 并轮询内容增长（不是看 setter 返回值）。
2. **AX 动作不可靠就视觉点击**：按钮有 `AXPress` 不等于它会响应；按「文字/矩形」点击更稳。
3. **无 AX 区域用截图 + OCR/视觉定位**：坐标必须绑定 `windowId`，并处理 Retina 缩放。
4. **凡是不可逆动作（发送、支付）先校验状态**；输入框为空时「发送」按钮为 `disabled` 是很好的安全断言。

## 9. 后台执行与非侵入式预览（v0.2 改造）

用户实测反馈：CLI 在操作微信时会反复把微信窗口拉到前台、抢输入焦点；原版 Codex 则是后台执行 +
系统级「正在共享」小窗预览。逐项排查与改造记录如下，完整实验见
[re/06-background-and-preview.md](https://github.com/V1ki/swift-computer-use/blob/main/re/06-background-and-preview.md)。

### 9.1 根因

- `getAppState` 走的是只读 AX，**不抢前台**（实测：Chrome 前台读微信后前台不变）；
- 所有输入动作都经过 `prepare()` → `NSRunningApplication.activate` + 窗口 raise + 全局
  `CGEvent`（`.cghidEventTap`），因此**每次点击/输入都会抢前台并移动物理光标**；
- 懒 AX 的自动激活也是前台化（微信冷启动时需要，暖态不需要）。

### 9.2 改造

| 项 | 改造 |
|---|---|
| 默认策略 | `setOptions {activate:false}`（默认）：不 activate、不 raise、不移动物理光标 |
| 语义动作 | `AXPress` / `AXValue` / `AXSelectedTextRange` 直接作用于后台 App；文本可 AX 直写（微信输入框实测可写） |
| 坐标/键盘 | 全部改为 `CGEventPostToPid` 定向投递（键盘、Unicode 文本、鼠标、滚轮、拖拽） |
| 前台化 | 显式 opt-in：CLI `--activate`、MCP/JS `set_options {activate:true}`；懒 AX 激活同受该开关控制 |
| 诚实失败 | 后台鼠标点击公开 API 投递不到 AppKit 控件 → 返回 `inputRejected` 并提示 `--activate`；`clickText` 用**结构性 AX fingerprint** 检测「AXPress 返回成功但界面没变」 |
| 预览 | 每窗口常驻 `SCStream`（2fps、空闲 20s 停止）；截图直接复用流帧 |

### 9.3 系统共享预览证据

```
# SwiftCUA 服务注册 SCStream
CUAService[98441] (ScreenCaptureKit) -[SCStreamManager registerStream:] Registering stream with streamID=…
CUAService[98441] (ScreenCaptureKit) -[SCContentFilter setContentsAndStreamTypeMacOS]: contentRect=[x=0 y=33 1512×949] pointPixelScale=2

# ControlCenter 接收并纳入共享流（这就是「正在共享」小窗的数据源）
ControlCenter[809] (ScreenCaptureKit) -[SCStreamInfo initWithConfiguration:contentFilter:]
ControlCenter[809] (ScreenCaptureKit) -[SCControlCenterManager updateStreamsWithType:config:contentFilter:]_block_invoke: didMatch 1 with type 3
```

截图经流返回：3024×1898 JPEG（1512×949 @2x），与一次性截图一致。
该机制对应 WWDC23-10136：每个 SCStream 都会自动出现在 Video 菜单/系统共享面板的 live preview 中，
无需 `SCContentSharingPicker.present()`。

### 9.4 仍存在的边界

1. **后台鼠标点击**：公开 API 的 `CGEventPostToPid` 对 AppKit 控件基本不生效（TextEdit 文档、
   微信侧边栏均实测无效，状态哈希不变）。原版靠私有 `SyntheticAppFocusEnforcer`（activation
   event tap + SystemFocusStealPreventer + VirtualCursor）让目标 App「以为自己是 key window」，
   公开 API 无法完全等价。因此需要像素点击的场景仍要 `--activate`（会抢前台并移动光标）。
2. **冷启动懒 AX**：微信等应用首次在被读取前需要激活一次；后台模式下只返回菜单栏树。
3. **自绘 PiP**：原版除系统共享面板外，还有自己的 `RemoteHostedPIPContentPublisher` /
   `RemoteHostedPIPWindowRenderer` / `CUAServiceRemoteHostedPIPController` + `NSStatusItem`
   常驻小窗；SwiftCUA 目前只复现了系统共享预览，未实现自绘 PiP。

## 10. 自绘 PiP 预览（v0.3）

对应原版的 `RemoteHostedPIPContentPublisher` / `RemoteHostedPIPWindowRenderer` + `NSStatusItem`。

### 10.1 实现

- `CUACore.PreviewHub`：actor 广播 `CUAPreviewFrame`（预编码 JPEG，Sendable）；
- `CUAEngine.WindowStream`：每帧额外生成 ~480px 缩略图并发布；
- `CUAService.PreviewUI`：`@MainActor` NSPanel（320×220、HUD、`.nonactivatingPanel/.borderless`、
  `level=.floating`、`canBecomeKey/Main=false`、`orderFrontRegardless`）+ `NSStatusItem`
  （`viewfinder` 图标），菜单含 显示/隐藏预览、停止共享、版本、退出；
- `ServiceEntry`：同步 main + `NSApplication` accessory run loop，socket 服务在 detached Task；
  `--headless` / `SWIFTCUA_HEADLESS=1` 保留纯后台模式。

> 踩坑记录：最初把 `NSApp.run()` 包在 `await MainActor.run { ... }` 里，主 actor 被长期占用，
> `PreviewHub` 订阅任务永远不执行（日志 `observers=0`），面板不出现；改为同步 main 入口后恢复。

### 10.2 实测

```
$ cua screenshot --window 152   # 触发窗口流
# 服务窗口：id=19263 layer=3 on=true bounds=986,292 320x220 name=SwiftCUA
# 前台 App：ChatGPT → 触发前后不变（不抢焦点）
```

- 面板实时显示 Chrome 画面，标题 `SwiftCUA · Google Chrome`，右上角 `停止共享` / `×`；
- 菜单栏出现 `viewfinder` 状态项（截图可见）；
- 停止请求后约 23s（20s 流空闲 + 3s 无帧）面板自动淡出：`on=false`；
- 面板固定 320×220（此前 Auto Layout 会撑成 496×310，改为手动 frame 布局）；
- 拖动位置写入 UserDefaults，重启后恢复并 clamp 在屏幕内。

### 10.3 边界

- 预览面板只显示**受控窗口**，不显示鼠标/点击轨迹；
- 面板不参与输入（`canBecomeKey=false`），点按按钮不会把焦点从用户当前 App 拿走；
- 高 DPI 下缩略图固定 ~480px 宽，仅用于预览，不影响 OCR/截图（全分辨率另走流帧）。

## 11. 「抢鼠标」取证与输入策略硬化（v0.4）

用户反馈新版微信下后台操作仍像在抢鼠标。做了三层取证与硬化。

### 11.1 静态审计

后台分支（`allowActivation=false`）不应有任何全局输入：

- 坐标点击 → 直接拒绝（`inputRejected`，提示 `--activate`）；
- 键盘/Unicode/滚动/拖拽 → `CGEventPostToPid`；
- AX 写值/选区/AXPress → 不触碰光标；
- PiP 面板为 `nonactivatingPanel`，不能成为 key/main，不使用 activate；
- SCStream `showsCursor=false`。

### 11.2 独立事件 tap 取证

`scripts/cursor-probe.swift` 用 CGEventTap 监听 `mouseMoved/leftMouseDown/leftMouseDragged`，
记录 `eventSourceUnixProcessID`：

- **空动作 10 秒 baseline**：捕获大量 `mouseMoved/leftMouseDown`，`sourcePID=0 / sourceState=1`
  （HID/hardware），轨迹连续变化——说明机器上存在真实的用户/硬件鼠标活动；
- **受控轮次**（手离开鼠标）：`state` / AX 写值 / pid Return 三步光标位移 **Δ=0**，前台 Chrome 不变；
  SCStream 5 帧期间出现的位移，tap 恰好捕获到 5 个 `sourcePID=0` 事件，没有任何来自微信、
  SwiftCUA 服务或探针进程的事件；
- **有外部输入的重跑**：TextEdit 只读 Δ121px、微信只读 Δ901px，但 tap 同样显示 PID0 事件源，
  `AX 写 Δ6.89px / Return Δ0`，Chrome 始终不变。

结论：**没有证据表明 SwiftCUA 在新版微信下 warp 光标**；历史大跳与该轮外部 HID 活动一致。
但由于用户确实在同时使用鼠标，无法把每次历史跳变百分百归因，报告保留这个不确定性。

### 11.3 硬化（代码）

- `InputSynthesis` 增加 `TaskLocal InputContext` + `EventPoster` 注入点：
  后台模式下任何全局 `CGEvent.post(tap:.cghidEventTap)` 直接抛 `inputRejected`（fail closed）；
- `launchApp` 的 `NSWorkspace.OpenConfiguration.activates` 跟随策略（后台 = false）；
- `performSecondaryAction` 在后台模式拒绝 `AXRaise`；
- CLI 对 action 类命令**必须**成功下发 `setOptions{activate: bool}`，失败即报错，避免上一次 `--activate` 残留；
- 诊断：`SWIFTCUA_TRACE_CURSOR=1` 时，每次 action 记录
  `phase/before/after/光标坐标/frontmost PID/globalPosts/pidPosts` 到 unified log（`subsystem dev.v1ki.swiftcua, category cursor`）；
- 新增 `scripts/verify-background.sh`：默认打开一次性 TextEdit 文档，`--wechat-self-chat` 需显式 opt-in
  且只认 `knight` 输入框、检测到非空草稿会拒绝运行；逐步输出光标位移、前台 PID、事件源；
- 新增 5 个 `InputPolicyTests`：默认拒绝全局事件、后台原语只走目标 poster、前台需显式允许、
  嵌套后台 scope 不能继承前台权限、无全局 post。

### 11.4 新版微信 4.1.15 适配结论

- AX 树仍可用（~112 节点，`list "会话"/"消息"`、`textArea`、`button "发送"` 结构不变）；
- 主窗口几何与窗口 id 变化，导航点击**仍需前台**（后台 pid 鼠标事件对 AppKit 不生效）；
- 后台 AX 写输入框可用；但**后台 Return 并没有把消息发出去**（实测文字仍留在输入框，
  随后已清空草稿），点「发送」按钮属鼠标点击，仍需 `--activate`；
- 因此能力矩阵维持：读 + AX 写值可后台；搜索/切会话/点发送必须前台。

## 12. 后台会话 API 实现及失败关闭实测（2026-10-29 12:04–12:17 +08:00）

本节是新的独立验证，不将历史成功线索当作本轮成功证据。**目标群打开、最新 8–12 条群消息、文件传输助手发送均未验证成功。** 没有给目标群发消息，没有使用 activate / AXRaise / kAXFrontmost / orderFront，没有重启或 kill 用户进程。

### 12.1 新增能力与测试

- Core/Engine/Service: `searchText` / `openChat` / `readChat` / `sendText`，CLI 对应 `search-text` / `open-chat` / `read-chat` / `send`。
- 强制后台 task-local policy；每个原语边界双采样 NSWorkspace + System Events；语义 AX 定位不依赖屏幕几何或脆弱数字索引。
- 发送仅允许 `knight` / `文件传输助手`，精确窗口或 composer 标题校验，拒绝覆盖草稿，发送一次并要求新增消息行 + composer 清空。
- 纯逻辑新增 5 测试：唯一精确结果、白名单与标题、发送后验证、禁止全局鼠标、协议 round-trip。
- `swift build --scratch-path .build-chat` exit 0；`swift test --scratch-path .build-chat` exit 0，60 tests / 0 failures（17 service + 26 engine + 2 core + 15 client）。见 [构建日志](<chat-build.log>)、[测试日志](<chat-tests.log>)。
- 采用临时独立 socket/headless 验证服务，未替换安装版。新命令使用说明见 [后台聊天文档](<BACKGROUND_CHAT.md>)。

### 12.2 操作路径和前台证据

| 路径 | 原语及结果 | 证据 |
|---|---|---|
| 首次群名搜索 | AXValue=完整群名成功；数字索引被新增清空按钮偏移，focus 命中错误元素。没有发送。改成每次语义定位。 | [初始 AX 树](<chat-probe-initial.log>)、[首次 focus](<chat-probe-search-focus.log>) |
| 语义搜索 | AXValue + AXFocused 成功且 read-back 为搜索框；PID Space/Delete 没有结果列表变化 | [结果](<chat-probe-retry-results.log>)、[焦点属性](<chat-probe-focused-inspect.log>) |
| 安装版 CLI | 后台 Space/BackSpace 返回 OK，但无导航效果 | [结果](<chat-probe-service-after.log>) |
| Down/Return | 搜索框内 PID 键导航无效果，当前聊天仍 knight | [结果](<chat-probe-open-result.log>) |
| 会话行 AX | AXSelected/AXPress 没有打开目标群 | [操作](<chat-probe-select.log>)、[结果](<chat-probe-select-result.log>) |
| 复现“文件”路径 | AXValue=文件 + AXFocused + PID Space/Delete，没有独立文件传输助手窗口 | [结果](<chat-probe-file-result.log>) |
| 新 open-chat | 精确群名 -> 搜索 -> 精确行 AXPress -> guarded Down/Return -> 标题校验失败，拒绝前台 fallback | [命令结果](<chat-command-open.log>)、[操作前](<chat-command-before.log>)、[操作后](<chat-command-after.log>) |
| 新 send 文件传输助手 | 在导航阶段失败关闭，未写 composer，未发送 | [结果](<chat-send-result.log>) |
| 新 read-chat knight | 独立 AXWindow=knight，AXTextArea=输入，AXList=消息 -> AXStaticText；只读成功 | [带时间戳结果](<chat-read-knight.log>) |

上表前后 probe 的 NSWorkspace / System Events 均记录 Chrome PID 1522。最后一条成功只读 `capturedAt=2026-10-29T04:15:41Z`，两个观察源均 Chrome 1522。

**不能声称整个时间段微信从未前台。** 04:15:49Z 新 send knight 在任何 AX 写或键事件之前，begin 护栏发现 NSWorkspace=Chrome1522、System Events=WeChat41969，立即中止，见 [拒绝证据](<chat-send-knight.log>)。本代理没有发出激活操作；期间还出现未由本代理设置的搜索词“零号”和独立 knight 窗口，提示外部并发操作，但原因无法确定。之后 Chrome 恢复，04:16:29Z 微信 AXWindows 已为空，见 [最终只读观察](<chat-current.log>)。无法在这个状态继续可靠导航。

### 12.3 群消息证据与缺口

本轮只能从会话列表看到目标群预览，**不是打开群后的最新消息列表**：
- 12:04：鳄策异辉 Rich：不知道这边服务员多少钱一个月，都很年轻漂亮。
- 随后预览：鳄策异辉 Rich：天天带几台电脑在水疗上班真的不错。

对应证据分别是 [初始树](<chat-probe-initial.log>) 和 [语义搜索后树](<chat-probe-retry-results.log>)。群聊天窗口标题/消息列表、8–12 条完整消息和 sender 都未取得，不编造。

残余风险：后台 PID 键在当前微信状态可能 no-op；AX 虚拟消息行可能空；独立窗 sender 未暴露；前台采样非连续证明；同名联系人不是强身份认证；低层旧 API 仍需调用方遵守发送限制。新 API 是保守实验适配层，不是已实测成功的后台微信导航解决方案。
