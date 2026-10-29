# SwiftCUA 线协议（IPC v1）

本文档描述 SwiftCUA 后台服务与客户端之间的完整线协议。它**不是**原 Codex Computer Use
协议的重放，而是一套独立设计；只有「4 字节小端长度 + UTF-8 JSON」的分帧方式与逆向观察到的
原服务一致（见 [`re/02-protocol.md`](../re/02-protocol.md)）。

## 1. 传输

| 项 | 值 |
|---|---|
| 类型 | `AF_UNIX` / `SOCK_STREAM` |
| 路径 | `~/Library/Application Support/SwiftCUA/IPC/computeruse.sock` |
| 覆盖 | 环境变量 `SWIFTCUA_HOME`（整体改根）或 `--socket <path>` |
| 权限 | socket 文件 `0600`，所在目录 `0700` |
| 单实例 | `flock` 锁 + 启动时探测既有 socket |

## 2. 分帧

```
┌──────────────────────────┬───────────────────────────────┐
│ length: UInt32 little    │ payload: UTF-8 JSON           │
│ endian, payload 字节数    │ （JSON-RPC 2.0 消息）          │
└──────────────────────────┴───────────────────────────────┘
```

- 长度字段不含自身（4 字节）。
- 单帧 payload 上限 **8 MiB**（8 388 608 字节）；超限即视为协议错误并断开连接。
- 帧可跨 TCP/UNIX 读边界任意切分；实现必须使用粘包安全的增量解码器（`CUAStreamDecoder`）。

## 3. 消息格式

标准 JSON-RPC 2.0：

```json
{"jsonrpc":"2.0","id":1,"method":"ping","params":{...}}
{"jsonrpc":"2.0","id":1,"result":{...}}
{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"click: missing app","data":{...}}}
```

- `id` 为整数或字符串；通知（notification）不带 `id`，服务端不回包。
- 服务端**只接受** `jsonrpc: "2.0"`；其它值返回 `invalidRequest`。
- 参数与结果字段统一 **camelCase**。

## 4. 握手

每个连接的第一条请求应为 `ping`：

```json
→ {"jsonrpc":"2.0","id":1,"method":"ping",
   "params":{"clientApiVersion":"SwiftCUA-IPC-1","clientName":"@swiftcua/sky",
             "clientVersion":"0.1.0","pid":12345}}
← {"jsonrpc":"2.0","id":1,"result":{
     "serverVersion":"0.1.0","apiVersion":"SwiftCUA-IPC-1","platform":"macOS",
     "features":["ax","screencapturekit","cgevent","mcp"],
     "permissions":{"screenRecording":true,"accessibility":true},
     "sessionId":"6F6C3B0A-…"}}
```

- `apiVersion` 主版本不匹配时客户端应告警；服务端不拒绝旧客户端，只在结果里回自己的版本。
- `sessionId` 由服务端签发；客户端必须在后续所有**面向 App** 的请求中原样回传。
- 未握手直接调用其它方法：服务端仍会处理，但没有会话 → 返回 `sessionNotFound`。

## 5. 方法表

所有面向 App 的方法都接受 `sessionId`。`app` 接受 bundle identifier、bundle 路径或可执行文件路径（不接受显示名）。

| 方法 | params | result |
|---|---|---|
| `ping` | `clientApiVersion` (req), `clientName`, `clientVersion`, `pid` | `CUAServerInfo`（含 `sessionId`） |
| `getPermissions` | `{}` | `{screenRecording, accessibility}` |
| `listApps` | `includeWindows?`, `sessionId?` | `{apps:[{id,displayName,isRunning,isInstalled,pid,activationPolicy,lastUsedDate,useCount,windows}]}` |
| `listWindows` | `sessionId?` | `{windows:[{id,app,title,bounds,layer,isOnScreen,isFocused}]}` |
| `getAppState` | `app` (req), `sessionId`, `includeScreenshot?`, `includeText?`, `disableDiff?`, `query?`, `windowId?`, `limit?` (1...6000), `depth?` (0...40) | `{state:{app,screenshot,text,accessibility,windows,info}}` |
| `click` | `app` (req), `elementIndex?` \| `x`,`y`；`clickCount?`,`mouseButton?`,`key?`,`durationMilliseconds?`,`windowId?`,`coordinateSpace?`,`strategy?` | `ActionResult` |
| `pressKey` | `app` (req), `key` (req), `durationMilliseconds?`, `windowId?` | `ActionResult` |
| `typeText` | `app` (req), `text` (req), `elementIndex?`, `windowId?` | `ActionResult` |
| `scroll` | `app` (req), `direction?` \| `scrollX`,`scrollY`；`elementIndex?`,`x?`,`y?`,`pages?`,`pixels?` | `ActionResult` |
| `setValue` | `app`,`elementIndex`,`value` (req) | `ActionResult` |
| `drag` | `app`,`fromX`,`fromY`,`toX`,`toY` (req) | `ActionResult` |
| `paste` | `app`,`text` (req), `format?`=`text`\|`md`\|`html` | `ActionResult` |
| `selectText` | `app`,`elementIndex`,`text` (req)；`prefix?`,`suffix?`,`selectionType?`=`text`\|`cursor_before`\|`cursor_after` | `ActionResult` |
| `performSecondaryAction` | `app`,`elementIndex`,`action` (req) | `ActionResult` |
| `captureScreenshot` | `app?` \| `windowId?` \| `displayId?` | `{screenshots:[...]}` |
| `findText` | `app` (req), `text` (req), `exact?`, `useOCR?`, `ocrOnly?`, `windowId?`, `limit?` | `{matches:[{index?,text,role?,rect,source,confidence?,windowId?}]}` |
| `clickText` | `app`,`text` (req), `exact?`, `useOCR?`, `ocrOnly?`, `windowId?`, `clickCount?` | `{match:{…}}` |
| `setOptions` | `activate?` | `{}` |
| `endSession` | 通知：`sessionId` (req) | 无（不回包） |

### AX 原语与结构化状态

新增 `axGet` / `axSet` / `axAction` / `axFocus` / `axAttributes` / `axActions`。
共同必填 `app`, `elementIndex`，可选 `sessionId`, `windowId`。
- `axGet`: `attribute` → `{attribute,value}`。
- `axAttributes`: → `{attributes:[{name,settable}]}`；未知可写性为 null。
- `axActions`: → `{actions:["AXPress",…]}`。
- `axSet`: `attribute`, `value` → `ActionResult`；仅写声明为 settable 的属性。
- `axFocus`: 设置 `AXFocused=true` → `ActionResult`，不隐式 raise App。
- `axAction`: `action`（必须在可用列表中）→ `ActionResult`。

AX 名称不区分大小写匹配。值支持 string/bool/finite number、`{x,y}`、
`{width,height}`、`{location,length}`（UTF-16 range）。读取 AX 引用仅给 role/title，
不递归展开；字符串截断到 16384 字符，数组最多 200 项，嵌套最多 4 层。
不支持类型返回 `{unavailable:...}`，不会伪造值。

`state.info` 含 pid/bundleIdentifier/name/activationPolicy/isActive、目标 window、
frontmostApp/frontmostPID、cursor（全局 points）和权限。
`accessibility.nodes` 含 index/role/subrole/title/value/description/identifier/states/actions/frame/children；
`truncated` 标记采集或输出裁剪，`snapshotId` 标识本次快照。
query/limit/depth 仅过滤展示，保留原始 index；depth=0 仅根，limit 计所有输出节点。
state/includeText=false 不要求 AX 权限；CLI `info` 默认不截图，仍读取 AX。

### ActionResult

`{accepted:true,changed?:bool,effect:"observed-change"|"unverified",path,evidence}`。
accepted 仅指 AX 接受或事件已投递；changed=false 仅表示短暂观察窗口未发现变化，
**effect 仍为 unverified，不表示操作成功或证明无效**。不可观察时 changed 缺省。
evidence 包含动作前后目标属性/窗口与前台 PID、光标；AX set 另含 requested/matchesRequested。
未检测到变化不自动重试（防止重复点击/输入）。属性/文本可能包含敏感内容，调用方应妥善处理。
clickText 保留 `{match}` 的旧兼容结果，不能据此断言界面变化。

### 元素索引语义

`elementIndex` 指的是**该 App 最近一次 `getAppState`** 建立的索引表内的序号：

- 表不存在或已过期（PID/window 不匹配、120 秒 TTL 到期、AX 引用失效）→ `elementIndexStale`；
- 序号越界 → `elementNotFound`；
- 索引表是引擎共享的 per-app 表（不是会话隔离），并在 `endSession` 时清空。
- 任何新 state/findText 捕获都可能替换表；索引不是跨快照稳定 ID，不保证识别所有 UI 重建。
- 显式 windowId 找不到或无法映射 AX 窗口时报错，不退回另一个主窗口。

### 坐标语义

- `click`/`scroll` 的 `x`,`y` 默认是**目标 App 窗口内**的 points（左上原点）；
- click 可设 `coordinateSpace:"global"` 使用全局屏幕 points；`strategy` 为 auto/ax/coordinate；
  element 与 x/y 互斥，auto 优先 AXPress，coordinate 显式绕过 AXPress，ax 不回退鼠标；
- `drag` 的四个坐标同上；
- 返回的 `screenshot.width/height` 为 points，`originX/originY` 为全局屏幕坐标。

## 6. 错误码

| code | 名称 | 含义 |
|---|---|---|
| -32700 | `parseError` | 帧内不是合法 JSON |
| -32600 | `invalidRequest` | 非 JSON-RPC 2.0 或缺少 method |
| -32601 | `methodNotFound` | 未知方法 |
| -32602 | `invalidParams` | 参数解码失败（message 前缀为方法名） |
| -32603 | `internalError` | 引擎内部错误 |
| 1001 | `permissionMissing` | `data.permission` = `Accessibility` \| `ScreenRecording` |
| 1002 | `appNotAuthorized` | `data.app` |
| 1003 | `appNotFound` | 应用不可发现 |
| 1004 | `appNotRunning` | 应用未运行且无法激活 |
| 1005 | `elementIndexStale` | 需重新 `getAppState` |
| 1006 | `elementNotFound` | 索引越界 |
| 1007 | `timeout` | 请求超时 |
| 1008 | `unsupported` | 引擎不支持该操作 |
| 1009 | `sessionNotFound` | 缺 `sessionId` 或会话已过期 |
| 1010 | `clientRejected` | 对端鉴权失败（连接层） |
| 1011 | `captureFailed` | 截图失败 |
| 1012 | `inputRejected` | 事件注入被系统拒绝 |

## 7. 超时与生命周期

- 客户端默认超时 30s（`ping` 5s），可用 `--timeout` 覆盖。
- 服务端为每个请求套内部 deadline，超时返回 `timeout` 而不是断连。
- 连接空闲 300s 关闭；服务退出时 unlink socket。
- 会话 TTL 24h；`endSession` 立即销毁。

## 8. 兼容性说明

- JS 桥 `@swiftcua/sky` 把本文协议包装成与原 `@oai/sky` 同名的方法（`list_apps` 等）。
- MCP server（`cua mcp` / `swiftcua-mcp`）把方法表映射为工具名（`list_apps`、`get_app_state` …），
  并额外提供 cua_repl 风格的 `js` / `js_reset` / `turn_ended`。
- 原服务的 socket 协议受代码签名对端校验保护，第三方进程无法直接连接（实测连接后立即 EOF）；
  SwiftCUA 的 `--require-peer` 可复现这一行为，但默认关闭以便开发。

## 9. 文本定位

`findText` / `clickText` 是通用文本定位原语，不封装业务流程。
AX 命中带 index，OCR 命中只有 rect/confidence，二者带所属 windowId。
useOCR 默认 true，ocrOnly 跳过 AX；OCR 仍需录屏权限。
后台稀疏树会如实返回，不设置 AXEnhancedUserInterface/AXManualAccessibility。
只有显式 activate=true 时，缺窗口 AX 的应用才允许激活后重新读取。
clickText 后台只尝试可用 AXPress；接受不等于生效；像素路径需要显式 activate。

## 10. 执行策略（默认后台）

- activate=false：不调用 activate，不向全局事件流注入。键盘使用 pid 定向投递；
  AX 可操作时使用 AX。无 element 的坐标 click 和 clickText 像素路径拒绝后台执行；
  element click 回退、scroll/drag 仍可 pid 定向投递，但不能假定应用响应。
- activate=true：允许激活及全局输入；激活失败则拒绝输入。不能保证应用响应或业务效果。
- AXRaise/AXFrontmost/AXMain 写入必须显式允许 activate。AXFocused 不自动 raise。
- 应用自身仍可能因 AX/定向事件激活或移动光标；不能保证阻止第三方应用行为。
- CLI 每次请求前下发 setOptions，默认 false。该选项为引擎级共享状态，
  不支持多个调用方并发切换激活策略；调用方应串行使用。动作内以 task-local 固定策略。
- foreground 操作不会自动恢复先前 App；需要由调用方负责恢复。
- MCP 保留原有工具，新增 AX 原语通过 CLI 或原始 RPC 调用；无业务 workflow 工具。
