# 05 — 懒 AX、部分 AX 与无 AX 应用的 macOS 控制路径

## 0. 结论与范围

调查：2026-10-29，macOS `27.2 (26B123)`，现有 Accessibility 授权有效。背景为 [04 引擎内部](<04-engine-internals.md>)、[02 协议](<02-protocol.md>)。本报告**只新增本报告和 [axless 实验材料](<raw/engine/axless/>)**；不修改实现、不做 git 操作、不发消息、不输入文字、不点击业务按钮、不调用原服务。

**最重要的结论：**

1. 微信不是“只能在前台读 AX”。沿用已有激活成功结论，本次测得：**暖启动后计划退后台的 0.8 / 5 / 30 秒采样点，实际前台均非微信，窗口树有 96–97 节点；最小化仍有 96；隐藏后窗口枚举归零，恢复显示并激活后有 97。** 这是有状态的可达性问题，不宜永久标记 AX-less。
2. **不应把 `AXWindows>0` 等同于内容就绪。** Cursor 窗口可只有 12 个壳节点，稍后达到 550+；Obsidian 可只有 9–10 个壳节点，开启后达到 672。纯应用根计数又会被数百菜单节点掩盖。
3. **AX 读取本身有观察者效应。** 同一采样先读 windowTree，再读 appTree，后者已经明显更深；Chromium 上游明确读取 `accessibilityRole` 可以激活 native/basic AX。因此“激活前后变多”不能单独证明必须激活。
4. **AX setter 返回值、flag 读回值、内容树深度三者不等价。** 多个 App 的 Enhanced 写入返回 `-25208`，但值实际改变；Cursor Manual 返回成功但读回一直 0，约 2.1 秒后树进一步变深；Obsidian Manual 立即读回 1。
5. **`WindowServerSPI.setWindowLocation(CGEventRef, CGPoint)` 是事件的窗口局部位置，不是移动用户窗口！** 现有符号不能证明原服务把窗口搬到隐藏桌面。PID 定向投递也不能推出任意应用后台输入必定成功。
6. 最稳路径是：**能力探测/有限唤醒 → 语义 AX → 有效索引的动作或几何定位 → 已验证快捷键 → 截图视觉/OCR 定位 → 坐标事件 → 状态校验**。OCR 是定位手段，不是点击后的最后一次“动作兜底”。

标签：**[实测]** 本机采样；**[已有]** 用户提供且未重复冷启动验证；**[源码]** 上游解释性证据，不等于已安装版本；**[二进制]** 原服务 nm/strings/已有反汇编；**[建议]** 工程设计，非成功率实证。

### 安全与实验边界

- 只采集 PID、bundle、角色统计、AXError、布尔 flag、窗口几何，不保存聊天、文档、标题、AXValue 正文。
- 实验包含经任务允许的激活、可逆 AX 开关；为 A 问题短暂最小化/隐藏微信并恢复。没有关闭、重启或创建项目。
- 截图完全在内存中用于 Vision，**没有图片落盘**，报告只列尺寸/统计。Vision 识别文字亦不保存。
- 若干时间点有外部前台切换（日志可见 DingTalk/Cursor/系统设置等）；只依据实测 `frontmost`/`active` 判定，不把计划标签当事实。未独占桌面，不能作严格性能基准。
- 未启动未运行 App，以免恢复会话、自动联网或登录；未操作 Space。没有测输入动作成功率，以下可靠性仅为适用条件，不编百分比。

## 1. 可复现工具与口径

主脚本：[probe.swift](<raw/engine/axless/probe.swift>)；聚合：[summarize.py](<raw/engine/axless/summarize.py>)；汇总：[summary.txt](<raw/engine/axless/summary.txt>)；运行清单：[inventory.jsonl](<raw/engine/axless/inventory.jsonl>)。

从仓库根运行（`switches` 会暂改可恢复布尔属性，`wechat` 会短暂最小化/隐藏；使用空闲桌面）：

```sh
swift re/raw/engine/axless/probe.swift inventory
swift re/raw/engine/axless/probe.swift snapshot com.tencent.xinWeChat
swift re/raw/engine/axless/probe.swift wechat
swift re/raw/engine/axless/probe.swift activate com.todesktop.230313mzl4w4u92
swift re/raw/engine/axless/probe.swift switches md.obsidian
swift re/raw/engine/axless/probe.swift manual-timing com.todesktop.230313mzl4w4u92
swift re/raw/engine/axless/visual-menu.swift com.tencent.xinWeChat 410
python3 re/raw/engine/axless/summarize.py
```

计数为去重 DFS：`AXChildren`、深度上限 35、节点上限 6000、每棵树约 8 秒预算，AX messaging timeout 0.4 秒。**windowTree** 是全部 `AXWindows` 根及后代，不含菜单；**appTree** 从应用根起算，含菜单，且在 windowTree 之后读取。截断值是下界，不称完整。树捕获不是原子事务，UI 变化会产生 ±1 或更多差异。

局限：预算在节点循环检查，不是可强制中断每次 IPC 的硬 deadline；timeout 设置是否对所有新 child ref 等效不能据本次证明。复现实验不应在卡死进程上无限等待。

### 已发现的测量陷阱

- 第一轮 [wechat-lifecycle.jsonl](<raw/engine/axless/wechat-lifecycle.jsonl>) 用 `Thread.sleep`，`NSRunningApplication.isActive`/workspace 状态未及时更新，标签称后台却仍报前台。该轮**不用于判断前后台**。最终脚本改为服务 runloop，见 [有效生命周期记录](<raw/engine/axless/wechat-lifecycle-runloop.jsonl>)。命令行辅助工具也要处理异步通知。
- `.activateIgnoringOtherApps` 在 macOS 14+ 已弃用且没有原有强制效果；返回 true 仅代表请求被接受，不证明目标仍在前台。产品代码应核验 PID，并在异步等待时让 runloop/执行器正常工作。
- 首次独立 SCK 试验进程退出 134，`CGS_REQUIRE_INIT`（SCContentFilter 构造时）；增加 `NSApplication.shared` / `NSScreen.screens` 初始化后退出 0。没有修改生产代码；不能把这次脚本进程初始化问题称为目标应用截图失败。

## 2. 微信懒 AX 的边界与机制判定

[已有] PID 1519、bundle `com.tencent.xinWeChat`，窗口 410，`(0,33,1512,949)`；未激活时 windows 空、main/focused nil、children 只有两个菜单栏。CGEvent 激活后可读 90+ 控件，包含整行 staticText 会话项、消息、输入框、按钮。**本次不重做该冷态实验。**

[实测] [有效记录](<raw/engine/axless/wechat-lifecycle-runloop.jsonl>)：

| 状态 | 真正前台 | AXWindows / windowTree | CG 410 onscreen | 结论 |
|---|---|---:|---|---|
| 已暖前台 | 微信 | 1 / 96 | true | 与已有结果兼容 |
| 切 Chrome 后约 0.8s | Chrome | 1 / 97 | true | 后台不立即销毁树 |
| 再等 5s | Chrome | 1 / 97 | true | 树继续可达 |
| 总等约 30s | DingTalk（外部切换） | 1 / 96 | true | 此时不是微信前台，仍有树；无法证明期间从未被他人激活 |
| 设置 `AXMinimized=true` | 微信 | 1 / 96 | false | **不可见并不必然屏蔽 AXWindow** |
| 恢复最小化，再 `hide()` | DingTalk | 0 / 0；appTree=197 | false | 隐藏应用的窗口不可从新枚举抵达，菜单仍在 |
| `unhide()` + activate | 微信 | 1 / 97 | true | 可恢复；E 始终为 1 |

hide/unhide 返回 false，但状态采样 `hidden=true/false` 和 CG/AX 变化确实发生；因此不单独依据 NSRunningApplication 方法返回值。最小化 setter/restore 均为 0。

### 能判定什么，不能判定什么

- **排除强假说**：“AXServer 按 CGWindow 当前 onscreen 位统一屏蔽不可见窗口”。最小化后 onscreen=false 但 AX 仍全量，构成反例。
- **排除强假说**：“微信每次失去 frontmost 必立即销毁/隐藏所有 AX 对象”。至少 0.8/5 秒的后台样本反驳它。
- **支持但未证明**：初次前台激活触发微信/其 UI 框架的 AX 懒初始化；隐藏触发另一条枚举策略。公开 AX 客户端只能观察可达对象，不能区分“对象真实销毁”与“应用不返回该对象”，更不能仅凭这些数据断言底层是微信代码还是 AppKit/桥接框架。
- **隐藏 ≠ 最小化 ≠ 其他 Space ≠ 被覆盖。** 不可互推。完整遮挡程度未量化；其他 Space 未测；>30 秒失效、重启、退出登录、主窗口关闭后重建未确认。

### 进一步因果实验设计（未执行）

1. 空闲测试账号/测试会话中，把冷态分三组：仅 AX 读 → 仅 E=true → 仅前台激活，各观察内容树首次出现时间。生产会话不能为了复原冷态随意重启微信。
2. 暖态保留 AXWindow 引用，隐藏后同时测新 `AXWindows` 和旧引用的 `AXRole/Children`：能区分“枚举不可达”与“旧引用失效”，仍不能证明服务端分配细节。
3. 用户授权后将同一窗口切换到另一 Space，记录 current Space、CG onscreen、App frontmost 与旧/新 AX 引用。不使用私有 Space API 偷改用户工作区。
4. 做受控 AppKit/自定义 NSAccessibility 小程序记录 accessibilityChildren getter 被调用及返回值；与 CG 可见性分离操纵，可验证系统传输层是否过滤。该实验只能验证通用 AX 机制，不能反推闭源微信实现。

## 3. AX 可用性矩阵

E=`AXEnhancedUserInterface`；M=`AXManualAccessibility`。数字以窗口子树为主；`≥` 表示截断。所有运行中行的 E 都被 advertised，getter/settable 查询成功；M 支持与否单列。`-25205`=attributeUnsupported；`-25208`=notImplemented。规模随当前内容改变，不是某产品常量。

| App / 类型与 bundle id | 窗口树：前样本 → 激活后 | E / M 初值与支持 | 开关后 / 懒创建判断 |
|---|---:|---|---|
| 微信，原生/混合；`com.tencent.xinWeChat` | 已暖 96→97 | E=1 可设；M 不支持 | 本次未改 E；暖态后台持续、隐藏归零；初次激活必要性沿用已有实测 |
| Chrome 156；`com.google.Chrome` | 3窗 ≥1419→≥1421，2 WebArea | E=1；M 不支持 | E setter -25208，内容基本不变；已暖，未测冷态 |
| Cursor 3.27.22，Electron；`com.todesktop.230313mzl4w4u92` | 1窗 12→≥550；0→1 WebArea | E=0、M=0，均 advertised/settable | E 后约 ≥575；M 定时测试 12→540→566（2.105s）；有按需 AX，**激活不是唯一触发** |
| 本机显示名 ChatGPT，Codex Framework；`com.openai.codex` | 1窗 1322→1323，1 WebArea | E=1；M 不支持 | E setter -25208，1323 稳定；不能套用另一个原生 ChatGPT bundle 的结论 |
| DingTalk 9.0.2，安装物含 Qt 框架；`com.alibaba.DingTalkMac` | 1窗 549→550 | E=1；M 不支持 | E setter -25208，550；本会话 AX 可用，不等于所有子页面都完整 |
| QQMusic 11.10.5；`com.tencent.QQMusicMac` | 0窗 →0；appTree=185 菜单 | E=0；M 不支持 | E 虽回 -25208 但读回1，窗口仍0；**同时没有 onscreen 普通 CGWindow，不能据此宣称可见 GUI 无 AX** |
| Obsidian 1.7.7，Electron；`md.obsidian` | 1窗 9→671，0→1 WebArea | E=0、M=0，均 advertised/settable | M=1 后672，恢复0后 windowTree=10；同次 appTree 又有968，显示读取唤醒效应 |
| Claude 2.37337.1，安装物含 Electron；`com.anthropic.claudefordesktop` | 未确认（未运行） | 未确认 | 未启动 |
| Blender 5.2.0，自绘候选；`org.blenderfoundation.blender` | 未确认（未运行） | 未确认 | 未启动，不预设新版没有 AX |
| Godot 4.7.1，自绘候选；`org.godotengine.godot` | 未确认（未运行） | 未确认 | 未启动，不预设引擎/导出游戏行为相同 |
| WPS 12.1.29182；`com.kingsoft.wpsoffice.mac` | 未确认（未运行） | 未确认 | 不把复杂办公 UI 一概标为自绘无 AX |
| Steam；`com.valvesoftware.steam` | 未确认（未运行） | 未确认 | 客户端、游戏、overlay 是不同目标 PID/窗口 |

证据：[激活/开关汇总](<raw/engine/axless/summary.txt>)、[Cursor 定时原始数据](<raw/engine/axless/timing-cursor.jsonl>)、[Obsidian 定时原始数据](<raw/engine/axless/timing-obsidian.jsonl>)。安装类型来自 plist 和 Framework 文件名，**非反汇编完整技术栈证明**。

为什么要多维分类：应用可能同时具备“原生菜单完整 + 内容自绘”“窗口 AX 完整 + 虚拟列表只暴露可见行”“WebArea 存在但 renderer 未就绪”“登录页可读、游戏区域无树”。应按 **PID/窗口/内容区域/当前 revision** 记录能力，而非按 App 名永久黑白名单。

## 4. Chromium / Electron 的两个开关

### 4.1 公开接口与非标准属性要分开

- `AXUIElementSetAttributeValue` 是 **Apple 公开 API**；`AXManualAccessibility` 是 **Electron 官方公开扩展契约**，不是所有 macOS App 必须实现的 Apple 标准属性。见 [Electron 官方文档](https://www.electronjs.org/docs/latest/tutorial/accessibility)。
- `AXEnhancedUserInterface` 是 **未文档化的屏幕阅读器相关属性**，即使可以通过公开函数写，也不能称为稳定 Apple 公共契约；**不是必须加载 SkyLight 私有 SPI** 才能写。
- [Electron 当前上游实现](https://raw.githubusercontent.com/electron/electron/main/shell/browser/mac/electron_application.mm) 同时处理 E/M，Manual 不调用 superclass，以避免记录 AXError 后看起来失败；Enhanced 仍走 super。与本机 E 返回 -25208 但读回改变的观察相容，不能证明安装版本逐行相同。
- [Chromium 上游实现](https://raw.githubusercontent.com/chromium/chromium/main/chrome/browser/chrome_browser_application_mac.mm) 与 Electron 都有读 `accessibilityRole` 启用基础/native AX 的路径。完整 screen-reader 模式不等于“有 WebArea 就够”。摘录可复现：[upstream.py](<raw/engine/axless/upstream.py>) / [源码摘录](<raw/engine/axless/upstream-switches.txt>)，取自调查时 main，非版本锁定证据。

### 4.2 延迟、计数与读回陷阱

上游为 Sonoma 的短时 on/off 抖动设置约 **2 秒 debounce**，每次新请求会取消旧定时并重排；VoiceOver 状态有优先权。其请求计数/模式生命周期不是简单“最后一次 bool 存储”。频繁每 100ms 重写 true 可能不断推迟生效，false 也可能影响其他 assistive technology 请求。

[实测] Cursor 不激活的 [timing-cursor](<raw/engine/axless/timing-cursor.jsonl>)：

| 样本 | 窗口节点 | M getter | 可解释结论 |
|---|---:|---:|---|
| 写前 | 12 | 0 | 壳已存在但内容未就绪 |
| setter 后首样本（标签0.000s，是读取开始时刻） | 540 | 0 | 基础树已出现，可能包含先前读 root 的唤醒效应 |
| 0.101–1.805s | 541 | 0 | 不能由 getter=0 判失败 |
| 2.105–3.204s | 566 | 0 | 与 2s 延迟补足模式相容，非精确 2s 生效测量 |
| 恢复原值0后 | 551 | 0 | 不是立刻回到“无内容” |

Manual setter 为 0；M 始终0不等于 App 已重置。上游 getter 使用 `GetAccessibilityMode() == kAXModeComplete` 精确比较，而启用路径带 platform/screenReader 位，这是一个解释候选，**未确认本机二进制就是该原因**。首样本本身需要若干 AX IPC，标签不是完成时刻。

[实测] Obsidian M 立即变1，树672，持续至3.2s；恢复0之后窗口树10，再读 appTree 却已968。旧版 Electron 与当前上游不能混作统一延迟常量。

**没有观察到可单独归因于 App 自发重置的 1→0。** 日志中的变0发生在本脚本显式 restore 后；Cursor 的持续0也不能伪装成 reset 证据。官方文档提到系统 assistive utility 可覆盖设置，上游也有 VoiceOver/去抖行为，属于机制风险而非本机已验证自重置。

建议：每 PID 做一次有限 capability probe；优先 Manual（已知 Electron），缺少它再考虑 E；不因属性未列举就永久否认（只在已知兼容适配器内允许安全尝试未列举的 setter）；保存原值与本次修改证据，**不去关闭原先为1的属性**；多调用方用进程内 lease/reference count；以内容 fingerprint/关键 role 增长验证，最多等待 3–4s，不高频重置 debounce。恢复须考虑其他 AT，不声称普通布尔恢复是无冲突事务。

## 5. 推荐控制序列与成功判据

### 5.1 策略表

下列输入都为建议，**本研究没有实际点击/打字，因此动作成功率未确认**。

| 路径 | 触发条件及优势 | 成功判据 | 主要副作用 | API 级别 |
|---|---|---|---|---|
| AX 语义 `AXPress` / action / `AXValue` / selection | 存在可用元素且动作/属性明确支持；不依赖文字像素 | 目标状态、选中/值/窗口变化符合预期；不是仅 err=0 | 值修改、搜索/提交仍可能有业务作用；读取敏感 AX 正文 | 公开 |
| AX 索引 | 最新 revision 中唯一匹配；索引只是定位，优先走同样语义动作 | refetch 后 PID/window/role/geometry 一致 | stale ID、整行 staticText 中心可能点错区域 | 公开，自定义索引层 |
| AX 几何点击 | 无语义 action，但节点有可靠 hit rect | 命中结果重读验证 | 通常需要激活，可能移动物理光标、触发 hover、首击只激活 | 公开 AX + CGEvent |
| 已验证快捷键/菜单动作 | 意图对应已知菜单命令，当前上下文/焦点正确 | 对应视图/状态变化 | 焦点错会操作别处；Return/快捷键可能发送/删除；菜单快捷键可能仅特定焦点有效 | 公开 AX 菜单/CGEvent |
| 窗口截图 + OCR 或视觉定位 | AX 无目标/部分区域自绘；有可共享窗口 | 文本候选唯一、坐标/窗口帧未变、动作后视觉变化 | Screen Recording 权限、隐私内容、OCR误识别；图标需视觉而非OCR | 公开 SCK/Vision |
| 纯坐标点击 | 当前截图/已验证模板坐标，定位置信度足够 | 新截图/AX 状态确认 | 最易受缩放、遮挡、动画影响；不可用历史固定坐标猜 | 公开 CGEvent |
| 原版后台 synthetic focus/virtual cursor | 仅有相应引擎、能力测试及用户允许 | 逐 App 验证事件、焦点与物理光标行为 | private API 兼容风险、不等于无扰动 | 公开+私有混合，不能完全等价 |

不是一条僵硬线性链：对“搜索”已知 Cmd+F 的界面，快捷键可能优于一个低置信 AX 行矩形；对自绘文字按钮，先 OCR 再坐标，而不是先瞎点坐标再 OCR。**不支持动作**可继续 fallback；**动作已发送但结果不明**应先重新观察，禁止重试链造成双发/双删。

### 5.2 伪代码

```text
observe(target, policy):
    require AX permission only for AX; check screenshot permission separately
    resolve running PID + explicit windowID; preserve current foreground/visibility
    snapshot = boundedCapture(window + applicationMenus)
    if window exists in CG but snapshot is menu-only / shell-only / requested role absent:
        probe known AX switches once with restore/lease policy     # public AX, custom attrs
        poll content readiness + notifications; max ~3–4s          # don't spam setters
    if still unusable and policy.allowActivation:
        unhide only if allowed; activate(target)                    # public AppKit
        await actual frontmost PID and UI settlement; bounded retry
        snapshot = capture again
    if still unusable:
        return screenshot + OCR/visual candidates + "AX unavailable/partial"
    return snapshot with session/PID/window/revision

act(intent, observation):
    verify target, newest revision, context and authorization
    if semantic action supported: execute once; verify result
    else if valid AX target geometry: consider semantic menu/shortcut, then click
    else if verified shortcut and correct focused context: execute once; verify
    else:
        image = capture exact windowID (not largest-window heuristic)
        target = unique OCR/visual match with calibrated transform
        if ambiguous/stale/low confidence: report/ask; do not click
        activate if needed; recheck window frame and target still valid
        post down/up or key pair; settle; verify new state
    on ambiguous outcome: observe before retry
    restore foreground only if safe and user has not taken over
```

自动 restore 前台不是总正确：用户正在另一个 App 操作时不要强抢回“原始前台”。用独占交互 lease 或检测真人输入/前台变化中止；观察-only 模式默认不激活，调用方明确允许才唤醒。

## 6. 自绘/无 AX 区域：截图、OCR、键盘、文本输入

### 6.1 本机只读视觉与菜单验证

脚本：[visual-menu.swift](<raw/engine/axless/visual-menu.swift>)。使用公开 ScreenCaptureKit 的 `desktopIndependentWindow`、关闭光标与单窗阴影，指定输出2×，Vision `.accurate` 中英识别。**指定2×只是实验配置，不证明显示器实际 backingScaleFactor 都为2。**

- Obsidian window186：frame `(0,33,1512,949)` → 图片 **3024×1898**；82 个 OCR 框，其中 confidence>0.8 仅7；14.02s。菜单296节点、44条非空 CmdChar。见 [结果](<raw/engine/axless/visual-menu-obsidian-initialized.jsonl>)。
- 微信第一次“取最大面积窗口”选到 **17834**，frame `(1512,-1410,1080,1890)` → **2160×3780**，17 个 OCR 框，confidence>0.8 为4，0.336s；**它不是已知主窗口410**。保留 [这条错误选择证据](<raw/engine/axless/visual-menu-wechat.jsonl>)，不把它当主窗口验证。脚本现支持显式 windowID。菜单198节点、41条非空 CmdChar。
- 显式指定微信主窗口410再次捕获：frame `(0,33,1512,949)` → **3024×1898**，61个OCR框、confidence>0.8 为15、0.401s，见 [主窗口结果](<raw/engine/axless/visual-menu-wechat-410.jsonl>)。这验证了窗口级截图与本地OCR可执行，不验证识别出的每条文字或坐标点击。
- OCR 数量和 confidence 不是文字准确率，没有人工逐字标注。首轮14s可能含冷加载/内容复杂度，不能与第二轮作产品性能比较。没有用 OCR 执行点击，未验证自绘 App 中的实际命中率。

### 6.2 坐标必须保存变换链

对无阴影、无裁切、原始方向图像，Vision 归一化框 `(x,y,w,h)` 为左下原点；若窗口捕获点大小为 `(W,H)`：

```text
localRect = (x*W, (1-y-h)*H, w*W, h*H)
screenPoint = capturedWindowOrigin + localRect.center
```

若输入是原始图片像素 `(u,v)`，应使用实际 `sx=imageWidth/capturedPointWidth`、`sy=imageHeight/capturedPointHeight`，不能固定除2。存在 resize/letterbox/crop/shadow 时先逆变换至 capturedContentRect，再加全局原点。

| 误差来源 | 处理要求 |
|---|---|
| Retina、截图缩小、不同显示器密度 | 分别保存实际 pixelSize 与 pointRect；跨屏窗口不能只拿主屏scale |
| 多显示器负坐标 | 本机已有 y=-1410、x=-1048；不得 clamp 到0；区分 AppKit 左下/Quartz 全局坐标 |
| 窗口阴影、标题栏、边框 | SCK ignoreShadowsSingleWindow；明确截图是否含标题栏，用实测contentRect，不凭截图外形猜偏移 |
| 系统缩放/截图配置 | width/height 的输出大小与 UI 逻辑点不同；保留 `sourceRect → outputPixels` |
| 动画、窗口移动、内容滚动 | timestamp/windowID/frame/revision 联合验证；动作前重新采样，等待稳定通知或两次一致 |
| OCR字框≠可点击控件 | 同文字多候选必须用区域/上下文约束；文字框中心可能在无响应 label，需要按钮/行容器几何 |
| 像素量化/JPEG字形 | 使用框中心安全内缩；小目标阈值、必要时重新无损捕获；不能用confidence替代命中验证 |
| 遮挡/隐藏/Space | 单窗后台截图可有旧内容，截图可见不代表事件可路由；必要时经许可真实激活后再定位 |

窗口级截图减少无关内容采集，但仍可能包含聊天/个人信息。OCR应本地执行、最小保留、错误日志不含全文；不能把屏幕内容当指令执行。

### 6.3 菜单快捷键提取（不打开菜单）

从应用 `AXChildren` 中的 AXMenuBar 遍历 AXMenu/AXMenuItem，读取 `AXTitle`（生产中只返回相关命令）、`AXEnabled`、`AXMenuItemCmdChar`、`AXMenuItemCmdModifiers`、`AXMenuItemCmdVirtualKey`、`AXMenuItemCmdGlyph`。本次脚本为隐私只保存按键和modifier，不保存标题；没有执行菜单。

公开 modifier 语义：Shift=1、Option=2、Control=4、NoCommand=8；**0 表示通常带 Command，不是“无修饰键”**。本机出现24/28等超出这四位的值，应保留 raw 值并对未知位降级，不冒充完整解码；功能键/箭头/emoji不能只用首个 Unicode 字符硬转 keycode。布局相关字符要用当前键盘映射。缺少快捷键属性可能是动态菜单尚未展开，或该命令确无快捷键；不能为了发现而自动执行命令/打开影响状态的页面。

### 6.4 剪贴板粘贴 vs 逐字符

- 长 Unicode/富文本：在用户允许剪贴板风险、目标支持粘贴时优先事务化 paste；保留所有 items/types，记录 changeCount，确认目标消费且剪贴板未被他人改动才恢复。只备份字符串会丢图片/富文本；历史管理器/跨设备剪贴板可能留副本，恢复不能撤销泄漏。
- 短命令/按键行为/拒绝粘贴字段：Unicode CGEvent 分块或硬件 keycode，按上下文选择；逐字符不等于真实 IME 输入，组合键、死键、CJK composition、游戏 raw input 各异。
- 有可靠 `AXValue` setter 时可省掉剪贴板和按键，但富编辑器可能不触发等同用户输入的事件。明确区分替换字段、追加文本、提交。
- Return 在微信可能发送；永远不为“确认输入成功”自动加 Return。本研究没有任何粘贴、逐字符或发送测试。

## 7. 原服务的非前台/AX-less 处理链：可证与不可证

静态提取：[evidence.py](<raw/engine/axless/evidence.py>) / [带原始行号的证据](<raw/engine/axless/static-evidence.txt>)；动态路径未执行。

```text
resolve app/window
 → AXEnablementAssertion（按上下文启用；生命周期持有/disable）
 → captureAXTree / captureScreenshot（可独立）
 → prepareToInteract / refetch / positionElement
 → semantic AX OR synthesized interaction
    → syntheticallyActivateIfNeededForSendingClick(...webView, coordinate, heldKey...)
    → SyntheticAppFocusEnforcer（真实 active 与 believed-active/focus 分开）
    → VirtualCursor + window-local event coordinates
    → CGEventAPI.postToPid
 → settle + recapture + cleanup/release assertions
```

这是符号支持的逻辑组织，不代表每个箭头都恢复了确切分支。

| 组件/证据 | 解决的问题（证据允许范围） | 公开等价与缺口 |
|---|---|---|
| AXEnablementAssertion，enableAccessibilityIfNeeded(window:context:) | 生命周期内保持必要 AX 模式；有 disable/deinit | 公开AX函数+扩展属性可做有限 lease；精确 kinds/上下文选择未恢复 |
| SyntheticAppFocusEnforcer，state中 actual active 与 believes focus/active 分离；menu dismissal suppression/event tap | 让目标处理合成事件时维持合适焦点/激活信念，降低菜单被真实前台变化打断的可能 | 真正 activate/AXFrontmost 是公开替代，但会抢前台；**无公开通用 API 保证伪造后台 App 的完整活动状态**；原版内部全部私有调用仍未逐项恢复 |
| VirtualCursor protocol，ComputerUseCursor conform，createVirtualCursorIfNeeded | 独立交互位置/按下状态及可视化的抽象；不应直接等同物理光标 | 公开 API 可维护逻辑光标/绘制overlay；保证不移动真实光标并兼容所有目标未确认；另有私有 setCursorUpdatesFromBackground |
| CGEventAPI.postToPid，`0x10025ec14` | 定向投递进程事件 | **公开** CGEvent.postToPid，可等价投递；不自动解决窗口选择、焦点、首击激活、游戏输入路径 |
| WindowServerSPI.setWindowLocation，`0x10027384c` | 签名输入是 **CGEventRef** 与 CGPoint，设置事件的窗口局部位置 | 原封装属于私有SPI；公开setLocation只负责全局坐标，不能声称相同；已有反汇编调用支持事件坐标处理 |
| 所谓“window relocation” | **未确认存在**；不能从上一个函数名推导真实窗口移动 | 若真的搬窗，AXPosition 可用于愿意配合的窗口（公开），但并非所有窗口可写；强制跨进程搬窗/Space控制通常需私有能力，此处没有已证原版链 |
| SCK + SkyLight截图双路径 | 获取窗口/关联窗口图像，未要求每次整桌面抓取 | 单窗口 SCK 公开；原版关联窗口、隐藏/透明/阴影精确行为及SkyLight路径无法宣称等价 |

[04 反汇编证据](<04-engine-internals.md#L233-L248>)指出 `0x10075ade0/0x10075ae3c` 实际调用 postToPid，`0x10075b454` 等调用 setWindowLocation。只凭符号存在不能断言私有链能对微信后台输入成功，更不能声称“无AX即可语义理解”；无AX时仍需视觉/键盘等定位与交互依据。

## 8. SwiftCUA 方法级改造建议（只建议，不改源码）

阅读当时实现已有 activation fallback 和 Vision OCR，以下是增量；共享仓库可能被 lead 同时修改，不把行号/实现状态当永久。

### P0：捕获可用性与 activate 重试

涉及 [SkyEngine.accessibilitySnapshot / prepare](<../Sources/CUAEngine/SkyEngine.swift>)、[AXSnapshot / AXAccess.windowCount](<../Sources/CUAEngine/AccessibilityCapture.swift>)。

- `hasWindowRoot` 只能判断壳存在，新增 `AXReadiness { menuOnly, shellOnly, contentReady, partial, timeout, permissionDenied }`，统计内容 roles、requested-target 是否存在、window/CG 对应情况。
- `capture → flags探测 → 内容轮询 → 经允许activate → 复查`，无窗口的 QQMusic 返回 noVisibleWindow，不伪报 AX-less；菜单-only 且 CG 有窗口才触发激活候选。
- NSRunningApplication.activate 返回后核实真实 frontmost PID；协作式 await/debounce，不在主执行器用 usleep；有限重试、记录每次恢复原因。最大重试后返回可用截图而不是无限激活。
- windowID 明确时不能因为 AX匹配失败就悄悄取另一个 main/largest window；返回歧义或降级为指定CG窗口视觉。

### P0：AX 开关探测要验证内容，不只验证 setter/窗口数

涉及 [AXAccess.enableAccessibilityIfNeeded](<../Sources/CUAEngine/AccessibilityCapture.swift>)。

- 返回结构体而不是 Bool：每个 flag 的 advertised/read/settable、old/new、setter AXError、请求时间、内容变化、lease/restore 状态。
- 已有 AXWindow 但12节点壳仍要探测；不在 `windowCount>0` 时立刻判完成。
- Cursor 实证要求 >=2s 之后再次测内容。上游会 debounce，**不要轮询中每隔几百毫秒重复写 true**；写一次→观察，真正检测到失效才退避重试。
- M getter false 不能判未启用；E setter失败不能判无副作用。副作用恢复也读回验证，并避免关闭别的AT已开模式。

### P1：OCR、快捷键及索引元数据

涉及 [VisionText.recognize / rect](<../Sources/CUAEngine/VisionText.swift>)、[ScreenCapture.image](<../Sources/CUAEngine/ScreenCapture.swift>)。

- `recognize` 返回 `OCRCandidate(text, confidence, pixelRect, windowPointRect, sourceWindowID, captureTime, transform)`，明确 pointSize 缺失是错误，不能静默把pixels当points再投事件。
- screenshot 输出保存实际imageWidth/Height、capturePointRect、crop/shadow policy；当前仅逻辑 width/height 不足以审计跨屏/缩放变换。
- 新增 `locateText(...exact/contains, region, minConfidence, allowAmbiguous:false)`；重复文本返回候选，不默认取第一；动作前重新校验frame/revision；OCR target和AX index使用不同命名空间。
- 新增 `AXAccess.menuShortcuts(pid:)` / `ShortcutResolver.resolve(intent, context:)`：提取CmdChar/Modifiers/VirtualKey/Glyph/enabled/path；保留未知位，去重同名菜单，禁止自动执行发现出的危险命令。
- 对多窗口点击和后台输入新增可观测日志但不含正文：targetPID/windowID、定位源AX/OCR、revision、activate结果、坐标变换版本、postcondition；真正业务输入回归测试须另获许可。

## 9. 未解问题与验收标准

未确认：微信冷态对象分配主体；隐藏后旧引用存活；其他Space/长期后台；实际完全无AX且可见的自绘/游戏应用；本机Cursor M getter长期0的确切二进制原因；App自发重置开关；原版synthetic focus/virtual cursor后台行为；任何输入动作成功率。

最低验收应覆盖：

1. menu-only、shell-only、完整树、timeout、无窗口五类状态不混淆；暖微信后台可读而隐藏可恢复。
2. Cursor/M setter=0/getter=0、E setter=-25208/值改变、Obsidian读AX又唤醒三个反直觉案例不误判。
3. SCK显式windowID、阴影关闭、多屏负坐标、输出缩放/裁切变换测试；OCR重名拒绝、窗口移动使候选失效。
4. 用户接管时停止激活/输入；动作结果不明先观察，不串行盲目fallback；恢复剪贴板/开关不覆盖并发修改。

本报告证实了可观测的 AX 生命周期和公开替代路径，**没有证明可以无扰动、后台、100%可靠地控制任意GUI**。
