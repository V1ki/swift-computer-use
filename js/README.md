# @swiftcua/sky

纯 Node.js（>=18，无第三方依赖）的 macOS SwiftCUA 客户端和 stdio MCP server。需要已安装并运行的 SwiftCUA 服务；此包不会启动服务、请求 TCC 授权或自动弹出授权对话框。

## 安装和导入

在使用方项目执行（本地包安装，不需要下载运行时依赖）：

```sh
npm install /absolute/path/to/swift-computer-use/js
```

把现有脚本中的 `@oai/sky` 改成 `@swiftcua/sky`：

```js
import { sky } from '@swiftcua/sky';

try {
  const apps = await sky.list_apps({ includeWindows: true });
  const app = apps.find(app => app.isRunning);
  if (app) {
    const state = await sky.get_app_state({ app: app.id, includeScreenshot: false });
    console.log(state.text);
  }
} finally {
  sky.close();
}
```

`sky.target === "mac"`。导入不会连接，首次操作才连接并执行 `ping` 版本握手。请在脚本结束时调用 `close()` 释放 Unix socket；`end_session()` 只通知服务释放会话，不关闭连接。

也可不安装，直接运行：

```sh
node examples/basic.mjs
node bin/mcp.mjs --socket /path/to/computeruse.sock
node --test test/
```

[示例脚本](./examples/basic.mjs)会列出应用、读取一个运行中应用的状态并输出文本树前 40 行。无服务时只输出清晰错误信息并以状态码 1 退出，不打印未捕获异常堆栈。

## 路径配置

优先级从高到低：

1. `createSky({ socketPath })` / MCP `--socket <path>`。
2. 环境变量 `SWIFTCUA_SOCKET`。
3. `createSky({ home })` / MCP `--home <dir>`，拼接 `IPC/computeruse.sock`。
4. 环境变量 `SWIFTCUA_HOME`，拼接 `IPC/computeruse.sock`。
5. `~/Library/Application Support/SwiftCUA/IPC/computeruse.sock`。

支持 `~` 和 `~/` 展开，空环境变量按未设置处理。`home` 指 SwiftCUA 数据目录而不是用户登录目录。`SWIFTCUA_SOCKET` 优先于 `--home`；要覆盖该环境变量请用 `--socket`。

```js
import { createSky, Transport } from '@swiftcua/sky';
const client = createSky({ home: '~/Library/Application Support/SwiftCUA' });
// 默认 autoConnect:true 表示首次调用自动连接，而不是构造时立即连接。
const manual = createSky({ socketPath: '/tmp/custom.sock', autoConnect: false });
await manual.connect();
manual.close();
```

## 客户端 API

主入口导出 `sky`、`createSky`、`Transport`，默认导出 `sky`。`@swiftcua/sky/client` 提供相同导出。`@swiftcua/sky/mcp` 导出 `MCPServer`、`runStdio`、`parseArgs` 和工具声明 `TOOLS`。

所有动作参数支持 camelCase 和 snake_case；同时提供时以 camelCase 为准。枚举值不转换，例如 `selectionType: "cursor_before"`。动作返回 `{}`，服务 JSON-RPC 错误保留 `message`、`code`、`data`。

| 方法 | 参数 / 返回 |
| --- | --- |
| `list_apps({includeWindows}={})` | `[{id, displayName, isRunning, lastUsedDate, useCount, windows}]` |
| `list_windows()` | `[{id,app,title,bounds,layer,isOnScreen,isFocused}]` |
| `get_app_state({app,includeScreenshot,includeText,disableDiff,query,windowId})` | `{app,screenshot,text,accessibility}` |
| `click({app,elementIndex,x,y,clickCount,mouseButton,key,durationMilliseconds,windowId})` | 元素索引或窗口相对坐标 |
| `press_key({app,key,durationMilliseconds})` | 按键或组合键 |
| `type_text({app,text,elementIndex})` | 输入文字 |
| `scroll({app,direction,scrollX,scrollY,elementIndex,x,y,pages,pixels})` | 方向或原始滚动量 |
| `set_value({app,elementIndex,value})` | 设置元素值 |
| `drag({app,fromX,fromY,toX,toY})` | 拖动 |
| `paste({app,text,format})` | 服务支持的粘贴格式 |
| `select_text({app,elementIndex,text,prefix,suffix,selectionType})` | 选择文本 |
| `perform_secondary_action({app,elementIndex,action})` | 辅助功能次要操作 |
| `capture_screenshot({app,windowId,displayId}={})` | 截图数组 |
| `ping()` / `permissions()` | 服务元信息 / 权限状态 |
| `end_session()` | 带自动生成的 sessionId 的 JSON-RPC 通知，返回 `{}` |
| `connect()` / `close()` | 可选的显式连接 / 本地关闭 |

截图为 `{url,width,height,id,zIndex}`，`url` 是服务提供的 data URL；`get_app_state` 未截图时返回 `screenshot:null`。缺失应用元信息采用稳定默认值：名称/日期 `null`、运行状态 `false`、使用次数 `0`、窗口 `[]`；缺失 accessibility 返回 `null`。

低层 `Transport` 继承 `EventEmitter`，提供 `connect()`、`request(method,params,{timeoutMs})`、`notify()`、`ping()`、`close()`，默认请求超时 30 秒。超时错误有 `code:"ETIMEDOUT"` 和 `timeout:true`。断线拒绝全部 pending，下一次调用可以重连；不会自动重放已经发送的动作。事件为 `connect`、`close`、`notification`、`transportError`。编码为 4 字节小端 UInt32 长度 + UTF-8 JSON，最大帧 8MiB，握手版本 `SwiftCUA-IPC-1`。

## MCP / cua_repl

[配置示例](./examples/repl-via-mcp.md)包含 Codex 和 Claude Desktop 配置。MCP 使用一行一个 JSON 的 stdio JSON-RPC，stdout 仅用于协议响应，日志写 stderr。协议版本 `2024-11-05`，工具：

- `js({code,title?,timeout_ms?})`：`code` 必填字符串，标题 1..80 字符，超时为 >=1 整数，默认 30000ms。
- `js_reset({})`：终止执行器并新建 VM 上下文；不会调用服务的 `endSession`。
- `turn_ended({hook_event_name,session_id,turn_id})`：三项均为非空字符串，记录事件并返回文本 `{}`，支持 Stop/Interrupt/SubagentStop 等名称。

上下文提供 `sky`、`cua`（同一对象）、捕获输出的 `console`、`sleep(ms)`、`json(value)`。支持 `return 1+1`、`await sky.list_apps()` 及可识别的最后表达式。返回 MCP 文本 content，包含 console 输出和结果，最多 25000 字符；执行错误通过 `isError:true` 返回，工具/参数错误使用 JSON-RPC `-32602`。

```js
console.log('当前应用');
const apps = await sky.list_apps();
return apps;
```

跨调用数据请显式存入 `globalThis`（例如 `globalThis.apps = await sky.list_apps()`）。每次代码包装在 async 函数内，所以顶层 `const` / `let` / `var` 不跨调用保留。复杂语句请显式 `return`，末尾表达式提取是无依赖的语法试探，不是完整 JavaScript AST 转换。

### 执行隔离与限制

VM 禁止字符串代码生成和 WebAssembly 代码生成，没有 `process`、`require`、动态 `import`、`Buffer`、文件系统、网络客户端或原生定时器。为避免 Node 默认动态导入错误泄漏宿主原型，执行前保守拒绝独立 `import` 词元（包括字符串和注释中的同名词元）。注入能力通过 JSON 字符串桥接，避免泄漏宿主函数构造器、Promise、异常原型。执行器使用有堆内存上限的独立 Worker；同步代码使用 VM `timeout`，整个异步调用还有宿主截止时间，超时终止 Worker 并重置上下文。大于 Node 定时器上限的 timeout 收敛到 2147483647ms。

**这不是操作系统级安全沙箱。** Node 的 `vm` 不承诺运行恶意代码的安全边界，Worker 仍处于同一 Node 进程。只运行可信自动化脚本；内存限制并不涵盖所有原生分配。`sky` 本身是有意授权的桌面控制能力，可以改变应用状态；超时或 reset 不能撤销已经发给服务的操作，也不能保证取消正在执行的原生动作。不要跨调用遗留未 await 的任务。

## 与 @oai/sky 的差异

- 兼容本文列出的 mac 方法，而不是原包的所有未公开能力；不支持 Windows/Linux 后端、自动启动器、原包内部路径、客户端注册或私有 MCP 工具。
- 使用 SwiftCUA socket / `SwiftCUA-IPC-1`，不是原服务协议地址。底层权限、元素索引生命周期、截图、输入行为取决于 SwiftCUA 实现和 macOS 权限。
- `capture_screenshot` 扩展返回截图数组，`permissions`、`connect`、`close` 和手动连接选项为本客户端补充。截图不保留线协议额外的 `originX`/`originY`/`windowId` 字段，app state 不暴露线协议额外的 `windows`。
- REPL 提供常用执行方式，但不支持模块加载、完整 Node 环境、跨调用词法声明或原插件图片输出通道。`turn_ended` 仅记录通知，不实现原插件的宿主 hook 系统。
- 测试只使用 fake Unix socket 和 MCP 子进程，不需要真实服务，不触发 TCC；尚未验证与真实桌面会话的端到端行为。
