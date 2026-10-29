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

所有面向 App 的方法都接受 `sessionId`。`app` 接受 bundle identifier、显示名或进程路径。

| 方法 | params | result |
|---|---|---|
| `ping` | `clientApiVersion` (req), `clientName`, `clientVersion`, `pid` | `CUAServerInfo`（含 `sessionId`） |
| `getPermissions` | `{}` | `{screenRecording, accessibility}` |
| `listApps` | `includeWindows?`, `sessionId?` | `{apps:[{id,displayName,isRunning,lastUsedDate,useCount,windows}]}` |
| `listWindows` | `sessionId?` | `{windows:[{id,app,title,bounds,layer,isOnScreen,isFocused}]}` |
| `getAppState` | `app` (req), `sessionId`, `includeScreenshot?`, `includeText?`, `disableDiff?`, `query?`, `windowId?` | `{state:{app,screenshot,text,accessibility,windows}}` |
| `click` | `app` (req), `elementIndex?` \| `x`,`y`；`clickCount?`,`mouseButton?`,`key?`,`durationMilliseconds?`,`windowId?` | `{}` |
| `pressKey` | `app` (req), `key` (req), `durationMilliseconds?`, `windowId?` | `{}` |
| `typeText` | `app` (req), `text` (req), `elementIndex?`, `windowId?` | `{}` |
| `scroll` | `app` (req), `direction?` \| `scrollX`,`scrollY`；`elementIndex?`,`x?`,`y?`,`pages?`,`pixels?` | `{}` |
| `setValue` | `app`,`elementIndex`,`value` (req) | `{}` |
| `drag` | `app`,`fromX`,`fromY`,`toX`,`toY` (req) | `{}` |
| `paste` | `app`,`text` (req), `format?`=`text`\|`md`\|`html` | `{}` |
| `selectText` | `app`,`elementIndex`,`text` (req)；`prefix?`,`suffix?`,`selectionType?`=`text`\|`cursor_before`\|`cursor_after` | `{}` |
| `performSecondaryAction` | `app`,`elementIndex`,`action` (req) | `{}` |
| `captureScreenshot` | `app?` \| `windowId?` \| `displayId?` | `{screenshots:[...]}` |
| `findText` | `app` (req), `text` (req), `exact?`, `useOCR?`, `ocrOnly?`, `windowId?`, `limit?` | `{matches:[{index?,text,role?,rect,source,confidence?,windowId?}]}` |
| `clickText` | `app`,`text` (req), `exact?`, `useOCR?`, `ocrOnly?`, `windowId?`, `clickCount?` | `{match:{…}}` |
| `endSession` | 通知：`sessionId` (req) | 无（不回包） |

### 元素索引语义

`elementIndex` 指的是**该 App 最近一次 `getAppState`** 建立的索引表内的序号：

- 表不存在或已过期（App 窗口重建、TTL 到期）→ `elementIndexStale`；
- 序号越界 → `elementNotFound`；
- 索引表是 per-app、per-session 的，并在 `endSession` 时清空。

### 坐标语义

- `click`/`scroll` 的 `x`,`y` 是**目标 App 窗口内**的 points；
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

## 9. 文本定位（为「无 AX / 懒 AX」应用设计）

`findText` / `clickText` 解决两类没有稳定无障碍树的应用：

1. **懒 AX**：AX 树只在 App 曾前台化后才创建（微信就是这样：未激活时只暴露菜单栏）。
   `getAppState` 与 `findText` 内部会检测根节点不是 `AXWindow`，自动激活目标 App 并等待
   ~1.2s 重新抓取；Electron 类应用还会尝试设置 `AXEnhancedUserInterface` /
   `AXManualAccessibility`（上游有 ~2s debounce，最长轮询 3s）。
2. **完全无 AX**：AX 树搜不到时（`useOCR` 默认 true），对目标窗口截图并调用 Vision 文字识别，
   返回窗口相对坐标的文本框。

`CUATextMatch.source` 区分命中来源：

- `ax`：带 `index`，可用后续 `click`/`setValue` 复用索引；
- `ocr`：只有 `rect` 和 `confidence`，点击走像素路径。

`clickText` 始终点击命中框中心（像素事件）：实测微信侧边栏按钮虽然暴露 `AXPress`，但语义动作
不会切页，而像素点击可以；因此「按看到的文字去点」走视觉点击更可预测。坐标仍是**窗口内 points**，
且匹配结果带 `windowId` —— 调用方必须把坐标应用到同一个窗口，否则多窗口/分离窗口应用会把点击
错位到别的窗口（微信就有一个 1080×1890 的分离窗口）。

`ocrOnly: true` 跳过 AX 查找直接走 OCR，便于验证像素路径或绕开已知错误的 AX 树。
