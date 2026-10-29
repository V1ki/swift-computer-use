# 兼容性：`@oai/sky` ↔ SwiftCUA

SwiftCUA 的目标是「能力等价 + 调用面可迁移」，**不是**与原服务字节级兼容。
把 `import { sky } from "@oai/sky"` 换成 `import { sky } from "@swiftcua/sky"`，
macOS target 的方法基本可以直接跑（见下表），返回值形状保持同构。

## 1. 方法映射（mac target）

| `@oai/sky` 方法 | SwiftCUA 线协议 method | CLI | MCP tool |
|---|---|---|---|
| `list_apps({includeWindows})` | `listApps` | `cua apps [--windows]` | `list_apps` |
| `list_windows()` | `listWindows` | `cua windows` | `list_windows` |
| `get_app_state({app, includeScreenshot, includeText, query, disableDiff, windowId})` | `getAppState` | `cua state --app ID` | `get_app_state` |
| `click({app, elementIndex, x, y, clickCount, mouseButton, key, durationMilliseconds})` | `click` | `cua click` | `click` |
| `press_key({app, key, durationMilliseconds})` | `pressKey` | `cua press-key` | `press_key` |
| `type_text({app, text, elementIndex})` | `typeText` | `cua type` | `type_text` |
| `scroll({app, direction, elementIndex, x, y, pages, pixels, scrollX, scrollY})` | `scroll` | `cua scroll` | `scroll` |
| `set_value({app, elementIndex, value})` | `setValue` | `cua set-value` | `set_value` |
| `drag({app, fromX, fromY, toX, toY})` | `drag` | `cua drag` | `drag` |
| `paste({app, text, format})` | `paste` | `cua paste` | `paste` |
| `select_text({app, elementIndex, text, prefix, suffix, selectionType})` | `selectText` | `cua select-text` | `select_text` |
| `perform_secondary_action({app, elementIndex, action})` | `performSecondaryAction` | `cua action` | `perform_secondary_action` |
| —（原 mac 无独立截图 RPC） | `captureScreenshot` | `cua screenshot` | `capture_screenshot` |
| —（原服务靠 AX 索引/私有路径） | `findText` | `cua find-text` | `find_text` |
| — | `clickText` | `cua click-text` | `click_text` |
| —（`ping` 由 transport 内部完成） | `ping` | `cua ping` | — |
| — | `getPermissions` | `cua permissions` | `get_permissions` |
| — | `endSession`（通知） | `cua session` | — |

## 2. 返回形状

```ts
// list_apps
[{ id: "com.apple.Safari", displayName: "Safari", isRunning: true,
   lastUsedDate: null, useCount: null,
   windows: [{ id: 1234, app: "com.apple.Safari", title: "…", bounds: {x,y,width,height},
               layer: 0, isOnScreen: true, isFocused: true }] }]

// get_app_state
{ app: "com.apple.Safari",
  screenshot: { id, url: "data:image/jpeg;base64,…", width, height, originX, originY, zIndex },
  text: "App: Safari (com.apple.Safari)\nWindow: \"…\"; elements=…\n[0] window …",
  accessibility: { tree, focusedElement, selectedText, selectedElements },
  windows: [...] }
```

## 3. 已知差异

| 项 | 原 `@oai/sky` (mac) | SwiftCUA | 影响 |
|---|---|---|---|
| 传输 | JSON-RPC over socket，仅 `ping`/`request` 两种 method，业务参数嵌在 `request` 里；连接级签名校验 | 直接 JSON-RPC 方法；连接默认不校验签名 | 不能直接复用原客户端的 socket 层；但 JS 桥对上层透明 |
| `get_app_state` 文本 | 服务端做 revision/diff，默认返回 diff（`~`/`+`/`-`） | 默认返回全量树，`disableDiff` 被接受但不生效 | 输出更冗长，但解析更简单 |
| 截图窗口 | 支持 bounded / 多窗口集合语义 | `app` 默认只截主窗口；`windowId` 精确指定 | 需要多窗口时逐个 `windowId` 调 |
| AX 树渲染 | 缩进 + 数字 ID + `[detail]`；标题头 `Window: "<title>", App: …` | 类似但格式独立：`[N] role "title" {states} actions=[…] frame=(…)` | 文本消费者需要适配（两者都不是稳定契约） |
| 元素索引 | 带 lineage/previousRevision，支持 stale 重取 | 每次 `getAppState` 重建表，过期返回 `elementIndexStale` | 语义更简单，需重新捕获 |
| 后台注入 | CGEventPostToPid + 合成焦点/虚拟光标 | 先激活 App 再 CGEvent 全局投递 | 会抢前台焦点/移动鼠标；非前台场景请用 `--no-peer-check` 本地服务并注意 UX |
| 私有 API | SkyLight / WindowServerSPI / AccessibilitySPI | 仅公开 API | 截图更慢，AX 树信息更少（例如拿不到部分私有节点/属性） |
| 锁屏 | 支持 | 不支持 | 刻意取舍 |
| `screenshotId` | Windows target 才有，mac 无 | 无 | 无差异 |

## 4. 迁移示例

```js
// before
import { sky } from "@oai/sky";
const apps = await sky.list_apps();
const state = await sky.get_app_state({ app: apps[0].id });
await sky.click({ app: apps[0].id, elementIndex: 3 });

// after
import { sky } from "@swiftcua/sky";
const apps = await sky.list_apps();
const state = await sky.get_app_state({ app: apps[0].id });
await sky.click({ app: apps[0].id, elementIndex: 3 });
```

如果需要保持包名不变，可在应用里做别名：

```json
{ "imports": { "@oai/sky": "@swiftcua/sky" } }
```

（Node 的 `imports` 只作用于 `#` 前缀内部说明符；跨包别名建议用 bundler 的 `resolve.alias`
或 pnpm `overrides`。）

## 5. MCP 兼容

SwiftCUA 提供两个 MCP server：

| server | 工具 | 用途 |
|---|---|---|
| `cua mcp`（Swift） | 14 个 sky 对齐工具 | 无 Node 依赖，直接用 |
| `swiftcua-mcp`（Node） | 上述 14 个 + `js` / `js_reset` / `turn_ended` | 与原 cua_repl 插件同形，脚本式调用 |

原 cua_repl 的三个工具签名保持兼容：

```json
// tools/list 摘要
{"name":"js","inputSchema":{"type":"object","required":["code"],
  "properties":{"code":{"type":"string"},"title":{"type":"string","minLength":1,"maxLength":80},
  "timeout_ms":{"type":"integer","minimum":1}},"additionalProperties":false}}
{"name":"js_reset","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}
{"name":"turn_ended","inputSchema":{"type":"object",
  "required":["hook_event_name","session_id","turn_id"],
  "properties":{"hook_event_name":{"type":"string"},"session_id":{"type":"string"},"turn_id":{"type":"string"}},
  "additionalProperties":false}}
```
