# SwiftCUA 架构

> 这是一个**独立实现**：SwiftCUA 不是 OpenAI 的产品，也不包含其代码。
> 它是在对用户本机安装的 `Codex Computer Use.app` 做只读逆向分析后，用 Swift 6
> 从零实现的一套等价的 macOS computer-use 系统，并在 JS/MCP 层提供可替换的兼容接口。
> 逐项逆向证据见 [`re/`](../re) 目录。

## 1. 目标与非目标

**目标**

1. 复刻「后台服务 + 客户端」的分层：一个常驻的 macOS 服务负责看屏 / 抓无障碍树 / 注入输入，客户端通过本地 IPC 驱动它。
2. 提供与原 `@oai/sky` 同形的 JS 对象（`sky.list_apps()` 等）与 cua_repl 风格的 MCP server，让已有脚本改一行 import 即可迁移。
3. 权限模型与用户预期一致：macOS Screen Recording + Accessibility，操作范围按会话授权到具体 App。

**非目标**

- 不追求与原服务 socket 的字节级兼容（原服务在连接级做代码签名 / 审计 token 校验，见 `re/03-security-model.md`）。
- 不实现锁屏后台操作（原服务通过 `/Library/Security/SecurityAgentPlugins` 的授权插件 + 锁屏守卫实现），这是刻意放弃的高风险能力。
- 不做自动更新（原服务用 Sparkle alpha feed）、不做遥测。

## 2. 进程与组件

```
┌────────────────────────────┐        ┌──────────────────────────────────────┐
│  客户端进程                  │        │  SwiftCUA.app (LSUIElement)          │
│                            │        │                                      │
│  · cua CLI (Swift)         │        │  CUAService                          │
│  · cua mcp (MCP stdio)     │◄──────►│   ├─ SocketServer (AF_UNIX)          │
│  · @swiftcua/sky (Node)    │  UNIX  │   ├─ PeerValidator (可配置签名校验)   │
│  · swiftcua-mcp (Node MCP) │ socket │   ├─ SessionStore (按会话授权 App)     │
└────────────────────────────┘        │   ├─ PermissionGate                  │
                                      │   └─ RequestRouter                   │
                                      │            │                         │
                                      │            ▼                         │
                                      │  CUAEngine (actor)                   │
                                      │   ├─ AppCatalog / WindowCatalog      │
                                      │   ├─ AXTree + AXFormat + 索引表      │
                                      │   ├─ Screenshot (ScreenCaptureKit)   │
                                      │   └─ InputSynthesis (CGEvent / AX)   │
                                      └──────────────────────────────────────┘
                                                       │
                                TCC: Screen Recording + Accessibility（按 App 授权）
```

模块边界（SwiftPM targets）：

| target | 职责 | 依赖 |
|---|---|---|
| `CUACore` | 协议、模型、帧编码、错误码、路径、日志 | 无 |
| `CUAEngine` | macOS 引擎实现（AX / 截图 / 输入 / 应用窗口枚举） | `CUACore` |
| `CUAService` | 可执行：服务入口、socket、鉴权、会话、路由 | `CUACore`, `CUAEngine` |
| `CUAClient` | 可执行：`cua` CLI + `cua mcp` | `CUACore` |
| `js/` | `@swiftcua/sky` + `swiftcua-mcp`（Node，零依赖） | — |

## 3. 分层职责

### 3.1 传输层 `SocketServer`

- `AF_UNIX`/`SOCK_STREAM`，套接字位于
  `~/Library/Application Support/SwiftCUA/IPC/computeruse.sock`（`SWIFTCUA_HOME` 可整体改根）。
- 文件权限 `0600`，目录 `0700`；单实例（`flock` + socket 探测）。
- 帧格式：**4 字节小端 UInt32 长度 + UTF-8 JSON**，单帧上限 8 MiB，与逆向观察到的原服务分帧一致。
- 每连接一个串行读循环，写操作串行化；空闲连接有超时；`SIGINT`/`SIGTERM` 优雅退出并清理 socket 文件。

### 3.2 对端校验 `PeerValidator`

原服务在**连接建立后、收到请求前**就会因「Sender process is not authenticated」断开（见
`re/raw/protocol/service-auth-log.txt`）。SwiftCUA 默认不做强制校验（便于本地开发与第三方集成），
但提供同一套能力：

- `getsockopt(..., LOCAL_PEERPID)` 取对端 pid；
- `SecCodeCopyGuestWithAttributes` + `SecCodeCopySigningInformation` 取 bundle id / team id；
- 配置 `config.json` 可要求 team id / bundle id 白名单，`--require-peer` 强制开启；
- 拒绝发生在协议层之前（直接关闭连接），与原有行为同构。

### 3.3 会话与 App 授权 `SessionStore`

- `ping` 建立会话，返回 `sessionId`；客户端在后续请求里回传。
- 每个会话维护 `allowedApps: Set<String>`，落盘为 TOML：
  `~/Library/Application Support/SwiftCUA/sessions/<sessionId>.toml`
  ```toml
  [apps]
  allowed = ["com.apple.Safari", "com.apple.systempreferences"]
  ```
- 未授权 App 的请求默认自动授权（`autoAuthorizeApps=true`，可通过配置关闭），关闭时返回
  `appNotAuthorized` 错误，宿主 UI 可调用授权接口后再放行。
- `endSession` 通知会删除会话文件并清空引擎缓存；会话有 24h TTL。

> 对比：原服务把「Always allow」持久化到
> `~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/Library/Application Support/Software/ComputerUseAppApprovals.json`，
> 会话级授权另有 `~/.codex/computer-use/sessions/*.toml`；SwiftCUA 简化为一份 session TOML。

### 3.4 权限门 `PermissionGate`

- Accessibility 缺失 → `permissionMissing("Accessibility")`
- Screen Recording 缺失 → `permissionMissing("ScreenRecording")`
- 检测用 `AXIsProcessTrusted()` / `CGPreflightScreenCaptureAccess()`，**不自动弹窗**；`cua doctor` 给出系统设置路径。

### 3.5 路由 `RequestRouter`

- 方法名与 JS API 对齐（camelCase）：`listApps`、`getAppState`、`click`、`pressKey`、`typeText`、
  `scroll`、`setValue`、`drag`、`paste`、`selectText`、`performSecondaryAction`、`captureScreenshot` 等。
- 每请求 deadline（默认 30s），超时返回 `timeout`；参数解码失败返回 `invalidParams`。

### 3.6 引擎 `CUAEngine`

四条管线：

1. **应用/窗口目录**：`NSWorkspace` + `CGWindowListCopyWindowInfo`。
   > 原服务用 Spotlight 查询（`kMDItemContentType == "com.apple.application-bundle"` 且最近 14 天使用）
   > 来构建 AppUsageCatalog，SwiftCUA 用 NSWorkspace + 目录枚举，语义等价、无私有依赖。
2. **无障碍树**：`AXUIElementCreateApplication` + `AXUIElementCopyMultipleAttributeValues`，
   带节流与上限的 DFS，输出 `CUAAccessibilityNode` 树 + `index → AXUIElement` 表；
   `AXFormat` 把树渲染成带索引的缩进文本（模型可读）。
3. **截图**：ScreenCaptureKit（`SCScreenshotManager`），JPEG → `data:` URL，返回 points 尺寸与窗口原点。
   > 原服务另有 SkyLight / `WindowServerSPI` 私有路径；SwiftCUA 只用公开 API，代价是首次截图更慢、且必须授予录屏权限。
4. **输入注入**：优先 AX 语义动作（`AXPress`、`AXValue`、`AXSelectedTextRange`），
   回退到 `CGEvent`（鼠标/键盘/滚动/拖拽）；`paste` 走剪贴板保存/恢复；坐标一律窗口相对 → 全局换算。

### 3.7 懒 AX 与 OCR 回退

并非所有 App 都随时提供 AX 树：

- **懒 AX**：AX 对象在 App 首次前台化时才创建。微信在后台时 `kAXWindowsAttribute` 为空、
  只有菜单栏；激活后立刻出现完整树（会话列表 / 消息列表 / 输入框 / 发送按钮）。
  引擎在根节点不是 `AXWindow` 时自动激活目标 App 并重抓，同时对 Chromium/Electron 尝试
  `AXEnhancedUserInterface` / `AXManualAccessibility`。
- **无 AX**：自绘 UI、游戏、部分 CEF 壳。`findText` 会退化为「窗口截图 + Vision OCR」，
  返回窗口相对坐标，再由 `clickText` 走像素点击。

`AXEnablementAssertion`、`SyntheticAppFocusEnforcer`、`VirtualCursor` 是原服务里承担同类职责的
组件（见 `re/04` / `re/05`）；SwiftCUA 用公开 API 实现了其中「激活 + 开关 + OCR」这条主线，
不做虚拟光标与合成焦点劫持。

## 4. 典型调用链

`sky.get_app_state({app: "com.apple.Safari"})`：

```
JS bridge → 帧(JSON-RPC) → SocketServer
  → PeerValidator（记录/可选校验）
  → SessionStore.isAuthorized(app)（未授权则按策略自动放行或报错）
  → PermissionGate（Accessibility / ScreenRecording）
  → SkyEngine.getAppState（AX 树 + 截图，重建索引表）
  ← CUAServerInfo/CUAAppState → JSON-RPC 响应帧 → JS 对象
```

随后 `sky.click({app, elementIndex: 42})` 复用上一次 `getAppState` 建立的索引表；
若表过期（窗口重建、TTL 到期），返回 `elementIndexStale`，客户端应重新 `get_app_state`。

## 5. 与原实现的刻意的差异

| 能力 | 原服务 | SwiftCUA |
|---|---|---|
| 传输 | JSON-RPC over UNIX socket + XPC 双通道 | 仅 UNIX socket |
| 对端鉴权 | 连接级签名/审计校验，第三方连接立即断开 | 可选（默认放行，配置开启后同构） |
| 私有 API | SkyLight / WindowServerSPI / AccessibilitySPI 等 | 仅公开 API（ScreenCaptureKit / AX / CGEvent） |
| 锁屏操作 | 授权插件 + 锁屏守卫，锁屏后可操作 | 不支持（刻意取舍） |
| App 发现 | Spotlight `MDQuery` | NSWorkspace 枚举 |
| 持久授权 | 组容器 JSON + 会话 TOML | 会话 TOML |
| 更新/遥测 | Sparkle alpha + Statsig | 无 |
| 协议兼容 | — | 与 `@oai/sky` 的方法面/返回形状对齐（非字节级） |

## 6. 构建与安装

```bash
make build          # swift build
make test           # swift test（不需要 TCC 权限）
make js-test        # node --test
make app            # 组装并签名 build/SwiftCUA.app
make install        # 安装到 ~/Applications + LaunchAgent
```

首次运行需要在「系统设置 → 隐私与安全性」中给 `SwiftCUA.app` 授予
**屏幕录制** 与 **辅助功能**；用固定签名身份（`CUA_SIGN_IDENTITY`）可让 TCC 授权在重编译后保持有效。

## 7. 安全须知

- 服务能看屏、能点击输入，等价于把用户桌面交给调用方：默认只允许本机同用户进程连接，socket 权限 `0600`。
- 会话授权按 App 记录；不要在生产环境打开 `autoAuthorizeApps`。
- 截图与 AX 文本可能包含敏感信息；SwiftCUA 不上传任何数据（无遥测），是否外发完全由调用方决定。
