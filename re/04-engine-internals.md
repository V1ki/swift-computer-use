# 04 — 操作引擎内部：截图、AX、输入与应用目录

## 0. 结论、证据边界与复现

**结论：该 macOS 服务不是简单的“AX 递归 + 前台 CGEventPost + 截屏”封装。** [二进制] 它具有窗口级截图的公开/私有双路径、带批量预取与裁剪的 AX 转换树、revision/lineage 与可重新定位元素的索引层，以及 PID 定向输入、虚拟光标和 synthetic focus 管理。公开 API 可以做出可用替代，但不能据此宣称后台交互、AX 文本或多窗口截图与原版完全一致。

证据标签：
- **[二进制]**：Mach-O 导入、可反混淆 Swift 符号、反汇编调用/分支。仅符号存在与已找到调用点分开写。
- **[字符串]**：字符串表、资源目录、plist/构建描述文本；不单凭字面串判定执行。
- **[JS]**：安装包的 mac target JS/API 文档；是接口契约，不保证当前服务实现与文档逐位一致。
- **[推测]**：工程复现方案、推导或尚待动态验证的行为；明确不是恢复出的源码。

样本：[SkyComputerUseService](</Users/v1ki/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService>)，24,934,560 bytes；SHA-256 `f21c31c0ee5df419dbd165bf76ebd65c64d864c6fec5b6c6c3a23c42ff3d2e13`，见[校验文件](<raw/engine/sha256.txt>)。地址均为该样本静态 VM 地址，运行时需要加 ASLR slide。

本次**没有**运行截图、读取当前用户 AX、注入输入、请求 TCC、附加调试器或终止进程。静态证据不等于运行时成功率测量。

复现工具与材料：
- [run.sh](<raw/engine/run.sh>)：`file`、`shasum`、`otool -L`、`nm -nm`、`swift-demangle`、`strings -a -t x`、`llvm-objdump`，以及资源目录清单。
- [完整符号](<raw/engine/nm-demangled.txt>)、[完整字符串](<raw/engine/strings.txt>)、[完整反汇编](<raw/engine/disassembly.txt>)、[动态库依赖](<raw/engine/dylibs.txt>)。
- [extract.py](<raw/engine/extract.py>)：从完整证据生成短符号表与地址段，不对原服务做修改。
- [公共 Swift API 样例](<raw/engine/PublicAPIExamples.swift>)：本报告提出的替代方案，已用本机 Xcode 的 `swiftc -typecheck` 检查；[检查记录](<raw/engine/swift-typecheck.txt>)为 `exit_status=0`。仅类型检查，未执行函数。

## 1. 平台边界：不能把 Windows/Linux 文档算成 mac 引擎

[JS] [mac API 文档](</Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/docs/sky-window-api.md#L12-L44>)明确 `target: "mac"`，输出 `{ app, screenshot: { url } | null, text }`，`disableDiff` 要求全量树。`element_index` 来自最近一次 `get_app_state()`。

[JS] [window2 文档](</Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/docs/sky-window2-api.md>)为 Windows target；bounded screenshots、screenshot ID、独立 `focused_element` / `document_text` 不能直接归给 mac。[full desktop 文档](</Applications/ChatGPT.app/Contents/Resources/cua_node/lib/node_modules/@oai/sky/docs/sky-full-desktop-api.md>)为 Linux target，含 `drag_handle` 与 AT-SPI states。Linux 的“不激活窗口/不移动物理指针”说明也不是 mac 保证。

[JS] mac 的 `set_value`、`select_text`、`perform_secondary_action` 都是真实接口，不应退化为仅坐标点击和打字。`paste` 契约包含恢复旧剪贴板；`select_text` 支持 `text`、`cursor_before`、`cursor_after` 及 prefix/suffix。

## 2. 主流水线

下图是由符号关系重建的**逻辑管线**，不是声称所有箭头都已逐一确认汇编 call；带 `*` 的关键路径另外取得了直接调用证据。

```text
mac sky JS
  app identifier / element_index / screenshot coordinates
        │
        ▼
NSWorkspace.resolveApplicationTargetPreferringRunningApplication
        │ ApplicationTarget(bundle ID + URL + target identifier)
        ▼
ComputerUseAppController
  lastAXTree / visibleRect / scalingFactor / scaledScreenSize
  focusEnforcer / virtualCursor / needsUISettleBeforeSkyshot
        │
        ├── updateSkyshot → SkyshotOperation.capture
        │      ├── captureAXTree
        │      │   AX enablement → transaction/cache → hierarchy prefetch*
        │      │   → visible children / partial arrays → transformed tree
        │      │   → render tree + source paths → revision/lineage → full/diff text
        │      └── captureScreenshot
        │          window ID(s) → screenshot configuration
        │          ├── ScreenCaptureKit / SCScreenshotManager*
        │          └── SkyLight helper → WindowServerSPI.captureWindowImagesInRect*
        │
        └── prepareToInteract(element ID)
               refetch/validate → positionElement → semantic AX or synthetic input
               → Unicode/key/mouse/scroll events → postToPid*
               → settle → optional new Skyshot
```

[二进制] 核心签名与地址：

| 地址 | 符号（省略命名空间） | 能确认的职责 |
|---|---|---|
| `0x10006eebc` | `updateSkyshot(treeCache:disableAXDiffing:skipScreenshot:) async throws` | 截图和 AX diff 可分别控制 |
| `0x100072dbc` | `prepareToInteract(with:cursorNextInteractionTiming:positionElement:animateCursor:)` | ID 到 refetchable tree + element |
| `0x100073530` | `positionElement(...) async throws -> Bool` | 操作前有元素定位阶段 |
| `0x100239558` | `SkyshotOperation.capture(...includeScreenshot:continuingFrom:performAccessibilityEnablement:)` | screenshot 可选、revision 可续接 |
| `0x10023a680` | `captureAXTree(...continuingFrom:...)` | 输出 `SystemSelection` |
| `0x10023b85c` | `captureScreenshot(imageSize:)` | 输出 `CGImage` |

来源：[截图符号摘录](<raw/engine/capture-symbols.txt>)、[AX 符号摘录](<raw/engine/ax-symbols.txt>)。

## 3. 截图：公开 SCK 与私有 WindowServer 均有实调用

### 3.1 明确存在的接口与配置

[二进制] `SlimCore.ScreenshotImplementation`：

```swift
captureScreenshotBuffer(appName: String?, delay: Int?, imageSize: CGSize?,
  includedWindowIDs: [UInt32]?, cropToFirstWindow: Bool,
  shouldBeOpaque: Bool, includeWindowShadow: Bool) async throws -> CGImage
captureScreenshotWithSkyLight(windowIDs: [UInt32], rect: CGRect) -> CGImage?
writeScreenshotToFile(appName: String?, screenshot: CGImage,
  encoding: ScreenshotEncoding) throws -> ScreenshotFile
bestMatchingWindow(in: [CGWindow], for: String) -> Window?
```

[二进制] `SkyshotOperation.init` 同时接受 `overrideScreenshotWindowID`、`additionalScreenshotWindowIDs`、`screenshotEncoding`、`screenshotShouldBeOpaque`、`screenshotIncludesWindowShadow`。因此不应将产品理解成永远只取一个无遮挡主窗口矩形；附加窗口和外观配置是设计的一部分。

### 3.2 不是仅“链接了框架”

- [二进制] `0x100f33f60` 明确调用 `+[SCScreenshotManager captureImageWithFilter:configuration:completionHandler:]`；`0x100f335bc` 调 `SCShareableContent`。
- [二进制] [分支摘录](<raw/engine/capture-branch.asm>)中 `0x100f37284` 建 `SCContentFilter(desktopIndependentWindow:)`，配置 `ignoreShadowsSingleWindow`、`ignoreShadowsDisplay=true`、`showsCursor=false`、`shouldBeOpaque`；`0x100f37364` 取 `pointPixelScale`，乘窗口宽高。
- [二进制] 同一截图区域 `0x100f37400` 调 `0x100f30dc8`；公开入口 `captureScreenshotWithSkyLight` (`0x100f30bb4`) 跳到这里。该函数在 `0x100f3102c` 调 `WindowServerSPI.captureWindowImagesInRect` (`0x100273b14`)。见[SkyLight 摘录](<raw/engine/capture-skylight.asm>)及[WindowServer 包装](<raw/engine/spi-windowserver.asm>)。
- [二进制] 私有包装读取动态解析函数指针并间接调用，而非 Mach-O 普通导入。该包装对 nil function pointer/空 window ID 列表能返回 nil。

**限制：** 已确认两种实现被调用，但本次没有完整恢复选择条件、错误 fallback 顺序、所有 crop 分支与多显示器合成规则。不得写成“总是优先 SkyLight”或“只在某 macOS 版本使用 SCK”。附近的 `isOnScreen` 检查也不足以独立证明全部分支语义。

### 3.3 可行替代与坐标约束

[推测] 公共替代优先采用以下本机已类型检查的调用（完整函数见[样例](<raw/engine/PublicAPIExamples.swift>)）：

```swift
let content = try await SCShareableContent.excludingDesktopWindows(
    false, onScreenWindowsOnly: false)
let filter = SCContentFilter(desktopIndependentWindow: window)
let config = SCStreamConfiguration()
config.showsCursor = false
config.width = max(1, Int(window.frame.width * CGFloat(filter.pointPixelScale)))
config.height = max(1, Int(window.frame.height * CGFloat(filter.pointPixelScale)))
let image = try await SCScreenshotManager.captureImage(
    contentFilter: filter, configuration: config)
```

[推测] 每次截图必须保存 **实际截取 rect、输出像素尺寸、scale、windowID、PID、时间/revision**。若无阴影且为线性缩放，截图像素 `(x,y)` 可通过 `global = crop.origin + (x/scaleX,y/scaleY)` 映射到屏幕点；阴影、裁剪、显示器坐标翻转和标题栏内外区域要单独计算。不能把 screenshot 像素直接送给 `CGEvent.location`，也不能假设所有屏幕 Retina scale 都是 2。

[推测] 不建议以已弃用或 SDK 不可用的 `CGWindowListCreateImage` 作为新实现主路线。公开 SCK 仍受录屏权限与窗口可用性约束；这里未验证遮挡/最小化/其他 Space 下与私有路径的一致性。

## 4. AX 读取不是直接 dump AXChildren

### 4.1 公共读写与私有层级预取

[二进制] 导入包含 `AXUIElementCopyAttributeValue(s)`、`CopyMultipleAttributeValues`、`CopyAttributeNames`、`CopyParameterizedAttributeValue`、`CopyElementAtPosition`、`IsAttributeSettable`、`PerformAction`、`SetAttributeValue`。

[二进制] 私有包装的真实 Swift 签名：

```swift
AccessibilitySPI.copyHierarchy(_ element: AXUIElement,
  attributes: CFArray, options: CFDictionary?,
  hierarchy: UnsafeMutablePointer<Unmanaged<CFDictionary>?>?) -> AXError
AccessibilitySPI.getWindowID(_ element: AXUIElement,
  identifier: UnsafeMutablePointer<UInt32>) -> AXError
AccessibilitySPI.getActualPID(_ element: AXUIElement,
  pid: UnsafeMutablePointer<Int32>) -> AXError
```

[二进制] [AX 调用摘录](<raw/engine/ax-hierarchy-call.asm>)在 `0x1006febb8..0x1006fec2c` 构造含以下键的 options，`0x1006fece0` 真正调用 `copyHierarchy`：
- `copyHierarchySkipInspectionForAttributesKey`
- `copyHierarchyArrayAttributesKey`
- `copyHierarchyTruncateStringsKey`：本段存入 Bool `true`
- `copyHierarchyMaxArrayCountKey`：从上层状态取值，不在本段硬编码

[二进制] 另有 `ResultValueKey`、`ResultCountKey`、`IncompleteResultKey` 包装。`UIElementTreeTransaction` 有 TaskLocal `current` 与 `prefetchEnabled`；`UIElementCache` 缓存 `supportedAttributes`。[字符串] 有 `AXManualAccessibility`、`AXEnhancedUserInterface`；[二进制] 有 `enableAccessibilityIfNeeded`、`AXEnablementAssertion.disable()`、`usesChromiumAccessibilityHierarchy`、`NSBundle.isElectronApp/isChromiumApp`。这支持“对部分应用额外启用/处理 AX”的结论，但未恢复每个应用的具体判定规则。

**私有 API 名称边界：** [AX SPI 解析摘录](<raw/engine/spi-ax.asm>)显示 `swift_once` 初始化动态函数表、编码数据和解析 helper。不能仅因网上存在类似名称就把 `_AXUIElementCopyHierarchy` 等拼写写成已从该样本确认的 dlsym 名。本次确认的是上述包装签名和实调用，不是完全解出的底层字符串。

### 4.2 可见性、截断与转换

[二进制] 找到：
- `visibleChildrenIfChildrenExceedsThreshold(_:context:)`
- `allChildrenFilteringVisibleElementsByPosition(includeSurroundingElementsUpToMax:includeAllVisibleItemRanges:clippingFrame:)`
- `visibleElementsCalculatingSubset(using:includeSurroundingElementsUpToMax:)`
- `partialArrayValue(for:maxCount:) -> (array, subsetDescriptor)`
- `AXArraySubsetDescriptor(count:availableRanges:)`
- `UIElementDepthFirstIterator`、`UIElementTraversalCounter`
- `ApplicationUIElement.flatTree(for:contextType:transformed:includingMenus:)`
- `UIElementTree<TransformedUIElement>.focusTree(context:)`、`addMenuBarWithImmediateItems`

[二进制] mac 转换项包括 `associateTitleUIElements`、`flattenRepetitiveStaticText`、`pruneNonDescriptiveSubtrees`、`flattenIntoSelectableAncestor`；通用层还有 `UIElementTreeTransformation.defaultPipeline`。这意味着渲染节点不必与原始 AX 节点一一对应。`NSAttributedString.axAttributedStringAsMarkdown` 和 `TransformedUIString.sourceRange(forMarkdownRange:)` 表明富文本 Markdown 转换保留源文本范围映射。

[字符串] `Max depth exceeded`；[二进制] diff API 有 `ignoreDifferenceLineBudget`、`onLineBudgetExceeded`。**未恢复最大深度、节点上限、时限、可见 children 阈值及 diff 行预算的确定数值**，不能随意填入常见的 50/5000/2 秒并标成原版常量。

[推测] 公共替代使用 `AXUIElementCreateApplication(pid)`，以 AXWindows/AXFocusedWindow 定位根；批量读 role/subrole/title/description/value/enabled/position/size/children，按需读 selected/focused/actions。采用可取消遍历、访问集、总预算和 `AXUIElementSetMessagingTimeout`，但是自选预算必须作为配置而非伪装成原版值。公开逐节点读取的 IPC 开销与截断语义无法等价私有 hierarchy API。

## 5. AX 文本格式、状态与 element_index

### 5.1 确认到的格式拼接

[二进制] `AccessibilityTreePresentation.init(windowTitle:applicationName:treeLines:focusedElement:selectedText:selectedElements:)` (`0x10063dd30`) 拼出：

```text
Window: "<windowTitle>", App: <applicationName>.
<treeLines joined with newline>
```

这不是依赖 strings 猜测：小字符串编码在 ARM64 immediates 中，例如 `0x203a776f646e6957` 解码为 `Window: `，随后附 `"`；`, App: ` 和 `.\n` 同理。见[格式反汇编](<raw/engine/render-presentation.asm>)。

[二进制] `UIElementRender.line(indent:indentCount:options:)` (`0x100644c70`)：
1. `text` 与可选 `detailText` 用空格拼接（unless withoutDetailText）。
2. 生成 `indent` 重复 `indentCount` 次的前缀。
3. 除非 withoutElementID 或 ID 为 nil，加入十进制 element ID、空格、正文。

见[行格式摘录](<raw/engine/render-line.asm>)。可以确认 **`<indent><decimalID> <text>[ <detail>]`**，而不是擅自写成 `[ID]`。缩进字符是参数，本次没有确认每个调用点都使用 tab，因此不把“固定两个空格”当产品事实。

[字符串] 静态输出片段：
- `Secondary Actions`
- `The focused UI element is `
- `Selected text: ``` `（实际字符串是冒号空格后紧接三个反引号；此处为 Markdown 排版多留一个空格）
- `Removed element IDs: `
- `The following is a diff from the previous accessibility tree`
- `with ~, +, and - representing changed, added, and removed elements, respectively.`
- `with ~ and + representing changed and added elements, respectively. Removed elements are summarized by ID range.`
- `The following is a cumulative diff from the initial accessibility tree`
- `There has been no change in the accessibility tree for `

### 5.2 例子：证实的框架，不是抓到的运行结果

以下是 **[推测] 示意内容**：标题、角色名、值文本和缩进选取是人为示例；只有上节已经确认的 header/ID 拼接方式与 diff 标记来自证据。没有执行 AX 捕获。

```text
Window: "Untitled", App: TextEdit.
1 window Untitled
  2 text area example
  3 button Close
```

对应 diff 可用 `~` / `+` / `-` 和 removed ID ranges 表达；本报告不伪造完整 diff 行布局。`focusedElement`、`selectedText`、`selectedElements` 是 presentation 的独立输入；不应仅靠递归 children 猜它们。

**状态说明：** [二进制] AX role/value/selected/focus/attribute render 模型存在，但本次未逐项恢复 selected/disabled/expanded/checked 状态的全部精确英语词形、标点和优先级。Linux AT-SPI 的整套 state list 不是本 mac renderer 的可引用输出字典。实现者可以在自己的规范中统一 `(disabled)` 等表示，但需标为自定义格式。

### 5.3 index 并非每次 DFS 的数组下标

[二进制] 相关符号：
- `UIElementRender.id: A` 与 `elementID: Int?` 是两个字段。
- `UIElementRender.sourcePath: IndexPath?` 连接 render 到 element tree。
- `setElementIDs`、`NextAvailableElementIDIterator`、`maxElementID`。
- `UIElementTreeRevision.lineageID`、`previousRevision`、`appending(tree:focusTree:render:)`。
- `UIElementTreeRevision.item(for: Int)`、`element(for: Int)`。
- `UIElementTreeTable` 保存 identity→ID 和 ID→path。
- `RefetchableSkyshotAXTree.refetchElementIfNeeded(Int, validateElement:)`、重载 `ignoreValueChange:`，以及 `refetchTree()`。

[字符串] 明确错误：
> The element ID is no longer valid. Try to get the on-screen content again and see if that resolves the issue.

另有 invalidated 后重新查找出现 **multiple elements were found that match the criteria**、无法开始 refetch、缺少 invalidation monitor 的错误；snapshot 要求 render 必须有 element ID，revision 要求 source path。

[推测] 因此等价结构应是“每 app/session 的 revision + identity table + live AX reference + refetch criteria”。变化后验证引用，唯一匹配才重新绑定；多候选应返回 stale/ambiguous 并让调用方重抓，不能随机选一个元素。符号强烈支持跨 revision 跟踪，但不证明 ID 跨进程重启、任意窗口切换或所有 diff 场景永久稳定。

## 6. 输入注入与高层操作

### 6.1 实际技术栈

[二进制] 不是只调用一次 `AXPress`，也不是所有动作都是物理鼠标：
- `UIElementProtocol.click(...alwaysSimulateClick:...focusEnforcer:virtualCursor:)`
- `ApplicationUIElement.syntheticallyActivateIfNeededForSendingClick(...isInsideWebView:...clickingByCoordinate:hasHeldKey:)`
- `ApplicationUIElement.sendClick(to:at:insideWebView:andDragTo:mouseButton:count:holdDuration:heldKey:flags:window:focusEnforcer:virtualCursor:)`
- `SyntheticAppFocusEnforcer.enforceActiveState/safelyEnforceActiveState/deactivateFocusEnforcer`
- `startSuppressingMenuDismissalEvents` / `stopSuppressingMenuDismissalEvents`
- `SynthesizedEvent.click(...inWindow:windowBounds:windowUsesFlippedCoordinates:)`
- `SynthesizedEvent.pressKeysForHolding` / `pressKeys` / `send(to:delay:)`

[二进制] `CGEventAPI` 有 `createKeyboardEvent`、`createScrollWheelEvent`、`keyboardSetUnicodeString`、`setIntegerValueField`、`setLocation`、`setFlags`、`setTimestamp`、`post`、`postToPid`、event tap 包装。[PID 输入摘录](<raw/engine/input-post-pid.asm>)显示 `0x10075ade0` 和 `0x10075ae3c` **实际调用** `postToPid` (`0x10025ec14`)，此前更新 timestamp。`0x1007378a8` / `0x100737914` 调 Unicode setter；`0x10075b454` 等调用 `WindowServerSPI.setWindowLocation`，支持窗口坐标事件处理。

[推测] 公共 `CGEvent.postToPid` 能做定向投递，但不能保证仅凭它就复刻 synthetic focus、窗口 routing、后台键盘焦点与虚拟光标行为。不可将“有 postToPid”扩展为“任何应用后台输入必定成功、完全不扰动用户”。

### 6.2 操作对照与推荐

| 操作 | 已确认原版证据 | Swift 替代方案与差异（[推测]） |
|---|---|---|
| element click | [二进制] `prepareToInteract`、`UIElementProtocol.click`、`alwaysSimulateClick` | 先验证 ID/可用状态；能用 AXPress 的简单控件可走 AX，否则定位后 CGEvent；原版精确选择条件未知 |
| coordinate click | [二进制] controller `click(at:with:clickCount:andDragTo:holdDuration:key:...)` | screenshot→screen/window 点转换，down/up 成对；click state、button、flags 保持一致 |
| drag | [二进制] click 与 synthesized event 都含 `andDragTo` | down→多点 dragged→up，异常/cancellation 也释放按键；插值节奏并未恢复 |
| press_key | [JS] `+` 分隔 keysym-style chord；[二进制] `SAIVirtualKeyPress`、holding pair | 自建 keysym→mac keycode/flags 表，按顺序 down、逆序 up，单独处理 modifier 和 hold duration |
| type_text | [二进制] Unicode event setter 与 keyboard action | UTF-16 Unicode event 分段；不等价于剪贴板粘贴，Return 有发送语义 |
| scroll | [二进制] `scroll(deltaX:deltaY:)`、scroll-wheel event wrapper | pixel wheel event，wheel1 纵向、wheel2 横向；pages→pixels 算法与 phases 的精确原版策略未恢复 |
| set_value | [JS] `client.setValue({app,elementIndex,value})`；[二进制] controller `setValue(...autosubmitSearchFields:)` | 检查 AXValue 可设性再写；是否提交搜索框必须显式策略，不能把所有 set_value 自动 Return |
| select_text | [JS] text/prefix/suffix/selection；[二进制] controller `selectText` | 找到文本的 UTF-16 NSRange，校验 prefix/suffix 歧义；AXSelectedTextRange 写入 CFRange；cursor_before/after 写 length=0 |
| secondary action | [JS] action+ID；[二进制] `performSecondaryAction`、AX action imports | 先 `AXUIElementCopyActionNames`，校验 action 属于列表后 `AXUIElementPerformAction` |
| paste | [JS] text/md/html、恢复旧剪贴板；[二进制] `performPaste(text:format:returnSkyshot:)` | 保存所有 items/types/data，写格式并 Cmd+V，等目标消费后恢复；必须处理用户中途修改的 changeCount 冲突 |

[字符串] select_text 错误明确要求 **settable selected text range**，不是随意用模拟 shift+arrow 替代。secondary action 错误包含 `is not a valid secondary action for`，应返回结构化错误而非悄悄 fallback。

[字符串/资源] [Slack 指引](</Users/v1ki/.codex/computer-use/Codex Computer Use.app/Contents/Resources/Package_ComputerUse.bundle/Contents/Resources/AppInstructions/Slack.md#L3-L12>)明确区分 `set_value` 和 `type_text` 的换行/发送语义。这说明把二者统一成 Cmd+V 或统一为键盘字符都不符合产品意图。

### 6.3 公共 AX 函数落点

[推测] 已类型检查的样例使用：

```swift
AXUIElementCopyAttributeValue(element, key, &result)
AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable)
AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
var range = CFRange(location: nsRange.location, length: nsRange.length)
let value = AXValueCreate(.cfRange, &range)!
AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
AXUIElementPerformAction(element, action as CFString)
```

生产实现应避免示意代码中的强解包，保留 AXError、PID/window/revision、操作类型以及触发重抓的错误原因；不要记录敏感输入正文。

## 7. 应用与窗口枚举

### 7.1 AppUsageCatalog 的来源已定位

[二进制] `AppUsageCatalog.App` 字段：`displayName`、`bundleIdentifier`、`appPath`、`targetIdentifier`、`lastUsedDate`、`useCount`、`isRunning`、`isFrontmost`。`loadApps(excluding:frontmostExcludingBundleIdentifier:timeout:)` 为 async throws，存在 indexedApps 与 indexingDidComplete Promise。

[二进制] [Spotlight 查询摘录](<raw/engine/app-spotlight-query.asm>)在 `0x10004bf88` 开始拼接：

```text
kMDItemContentType == "com.apple.application-bundle" &&
kMDItemFSName == "*.app" &&
kMDItemLastUsedDate_Ranking >= $time.today(-14)
```

`0x10004bfa4` 的 `0xe` 经整数格式化附到查询，`0x10004bfd8` 附右括号；`0x10004c010` 调 `MDQueryCreate`，随后配置 dispatch queue 和 `kMDQueryScopeComputer`。**14 天是本段可恢复的实际常量**，不是估计。该查询说明应用目录至少使用近期 Spotlight 元数据，不能描述成单纯递归扫描 /Applications。

[字符串] `kMDItemLastUsedDate_Ranking`、`kMDItemUseCount`；[二进制] 有 MDItemCopyAttribute(s)/MDItemCreate 导入与日期/整数取值 helper。具体排序优先级和运行中/未使用应用的合并规则未完全恢复，不能直接断言输出只包含过去 14 天应用。

### 7.2 target resolution 与窗口

[二进制] `ApplicationTarget.init(bundleIdentifier:bundleURL:)`、`identifier(for: URL)`；NSWorkspace 扩展有：

```swift
resolveApplicationTarget(for: String) throws -> ApplicationTarget
applicationTargets(withBundleIdentifier: String) -> [ApplicationTarget]
resolveApplicationTargetPreferringRunningApplication(for: String) throws -> ApplicationTarget
runningApplicationTargets(withBundleIdentifier: String) -> [ApplicationTarget]
runningApplication(for: ApplicationTarget) -> NSRunningApplication?
```

[二进制] 窗口层导入 `CGWindowListCopyWindowInfo`、`CGWindowListCreate`、`CGWindowListCreateDescriptionFromArray`，还存在 SCWindow 与 AXWindow 表示；私有 `AccessibilitySPI.getWindowID` 连接 AX 与 CG window ID，`WindowServerSPI.associatedWindowIDs` 能找关联窗口。

[推测] 公开替代：NSWorkspace.runningApplications + Spotlight/LaunchServices 获取已安装 app URL；用 bundle URL 区分重复 bundle ID 的多份应用。窗口列表以 PID/window ID 为主键，AX 标题、位置、尺寸辅助匹配，而不能仅凭窗口名字符串选第一个。公开 AX 未提供与该私有 getWindowID 完全同等的通用连接手段，几何匹配存在同名/重叠窗口歧义，需向调用层暴露。

## 8. Package 资源与构建线索

[字符串/资源] 完整[资源清单](<raw/engine/resource-manifest.json>)：

| 资源包 | 实际可见内容 | 对引擎的意义 |
|---|---|---|
| Package_Appshot.bundle | Info.plist、Appshot.wav、签名 | 资源包不是独立可执行截图引擎；具体代码在主 Mach-O/链接模块中 |
| Package_ComputerUse.bundle | AppInstructions 7 个 Markdown、Assets.car、LensSequence PNG、SkysightSummarizer/MemoryInstructions、签名 | app 专属指引、UI 动画/图像资源、Skysight 记忆提示文本；不是 AX dump fixtures |
| Package_SlimCore.bundle | Info.plist、Assets.car、签名 | 通用资源，不含可直接复用的操作实现源码 |
| SwiftProtobuf_SwiftProtobuf.bundle | PrivacyInfo.xcprivacy 等 | 第三方库资源 |

[字符串/资源] 三个 Package bundle 中**未发现** BUILD.bazel；但 Resources 根有[构建描述副本](<raw/engine/BUILD.bazel.txt>)。其 `swift_library(name="CUAServiceSources", module_name="CUAService")` 依赖 `ComputerUse`、`ComputerUseClient`、`SlimCore`、`GraphicsSupport`、`Fog`、`Logging`、`OAIProtobuf`、`OAIStatsig`、Sparkle、SwiftProtobuf 等；含 Objective-C launcher `main.m` target。`bundle_id` 为 `com.openai.sky.CUAService`、app group 为 `2DC432GLL2.com.openai.sky.CUAService`、最低 macOS `14.4`。

此构建文件暴露模块划分和最低系统版本，不等于完整 Bazel workspace，也不表示资源包里保存了 Swift 源码。Skysight 提示内容属于被分析的程序资源，不是研究过程应遵循的指令。

## 9. 最小可用等价实现与无法声称等价的部分

[推测] 建议分层：
1. **AppCatalog/WindowResolver**：bundle URL、PID、windowID，查询/超时/重复 target 处理。
2. **CaptureService**：SCK 截图、坐标元数据、PNG/JPEG 编码与临时文件生命周期。
3. **AXSnapshotBuilder**：公开 AX、批量属性、visible/partial tree、预算/超时；有声明的简化文本格式。
4. **SnapshotStore**：app/session/revision，数字 ID 与真实 element reference 分离，stale validation/refetch。
5. **ActionExecutor**：AX semantic action/value/selection 与 CGEvent 合成分路，统一取消清理/键释放。
6. **ClipboardTransaction**：保存所有 pasteboard items，消费后条件恢复，避免覆盖并发用户修改。
7. **PostActionSettler**：通知/debounce/短超时重采样，不把固定 sleep 误当视觉稳定检测。

| 功能 | 公共 API 可行性 | 明确缺口 |
|---|---|---|
| 单窗口截图 | 高，样例已类型检查 | 原版 SkyLight/多窗口/透明阴影行为未完全复现 |
| AX 文字/元素 ID | 高，可自定义规范 | 私有批量 hierarchy 性能、剪枝/format 精确规则 |
| 点击/键盘/滚动/drag | 高，需权限与目标测试 | synthetic focus、窗口路由、后台行为与特殊应用兼容 |
| set_value/select_text/actions | 高，但依赖元素支持 | app-specific fallback/autosubmit/富文本范围映射 |
| app/window 枚举 | 高 | 原版排序、recent/running merge、AX↔CGWindow 私有关联 |
| diff 与 refetch | 可工程实现 | 原版身份匹配规则、line budget、所有 invalidation 来源 |

验收应分为三层：**类型检查**（本次完成）、**获授权后的功能测试**（本次未做）、**与原版的行为对照**（本次未做）。尤其要覆盖多显示器/缩放、Electron、同名多窗口、节点销毁重建、modal sheet/menu、复杂剪贴板和 Unicode 文本。静态分析足以指导架构，但不应以这些证据宣称已经完整克隆。
