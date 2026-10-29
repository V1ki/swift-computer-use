# 在 Codex / Claude 中使用 SwiftCUA MCP

Node >=18（推荐 24）。MCP server 不会启动 SwiftCUA 服务，也不会自动申请权限。请先按 SwiftCUA 部署流程启动服务并授予必要权限，然后设置 socket 路径。配置中的路径必须改成你的绝对路径；GUI 启动的客户端不一定继承 shell PATH，因此建议 `command` 使用 Node 可执行文件的绝对路径。

## 通用 MCP JSON / Claude Desktop

Claude Desktop 的 MCP 配置使用如下 JSON（合并到已有配置，不要覆盖其他 server）：

```json
{
  "mcpServers": {
    "swiftcua": {
      "command": "/absolute/path/to/node",
      "args": [
        "/absolute/path/to/swift-computer-use/js/bin/mcp.mjs",
        "--socket",
        "/Users/yourname/Library/Application Support/SwiftCUA/IPC/computeruse.sock"
      ]
    }
  }
}
```

也可省略 `--socket`，改为 `env`：

```json
{
  "mcpServers": {
    "swiftcua": {
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/swift-computer-use/js/bin/mcp.mjs"],
      "env": {"SWIFTCUA_HOME": "/absolute/path/to/SwiftCUA"}
    }
  }
}
```

## Codex

Codex 本地配置原生使用 TOML，而不是上述 JSON：

```toml
[mcp_servers.swiftcua]
command = "/absolute/path/to/node"
args = ["/absolute/path/to/swift-computer-use/js/bin/mcp.mjs"]

[mcp_servers.swiftcua.env]
SWIFTCUA_HOME = "/absolute/path/to/SwiftCUA"
```

也可通过 CLI 注册：

```sh
codex mcp add swiftcua -- /absolute/path/to/node /absolute/path/to/swift-computer-use/js/bin/mcp.mjs
```

在客户端重新加载 MCP 配置后，应该看到 `js`、`js_reset`、`turn_ended` 三个工具。注册 MCP 不等于已连接到桌面服务；首次 `sky` 操作才连接。

## 调用示例

`js` 工具 arguments 的 JSON 示例：

```json
{
  "title": "列出当前应用",
  "code": "const apps = await sky.list_apps({includeWindows:true}); console.log(apps.length); return apps;",
  "timeout_ms": 30000
}
```

读取应用状态并截取文本树：

```json
{
  "title": "读取应用状态",
  "code": "const state = await cua.get_app_state({app:'com.apple.TextEdit', includeScreenshot:false}); return state.text.split('\\n').slice(0,40).join('\\n');"
}
```

`js_reset` 的 arguments 是 `{}`。若要跨调用持久保存变量，使用 `globalThis.saved = ...`，不是函数局部的 `const`/`let`。

`turn_ended` 的 arguments：

```json
{"hook_event_name":"Stop","session_id":"session-123","turn_id":"turn-456"}
```

该工具只记录日志并返回文本 `{}`；宿主若需要在 Stop/Interrupt/SubagentStop 时自动调用，必须单独配置相应 hook，MCP 注册本身不会安装 hook。

## 故障排查

- `ENOENT` / `ECONNREFUSED`：检查 SwiftCUA 服务是否启动，以及 socket 路径。优先级：`--socket` > `SWIFTCUA_SOCKET` > `--home` > `SWIFTCUA_HOME` > 默认目录。
- 权限错误：检查 SwiftCUA 服务的辅助功能/屏幕录制权限。MCP 不会绕过 TCC。
- `process is not defined` / 禁止动态导入：这是受限 VM 的预期行为，仅注入 `sky`、`cua`、`console`、`sleep`、`json`。
- 执行超时：上下文可能已重置；不要重试不可重复的桌面动作，先读取实际应用状态。超时不能撤销已经发送的操作。
- server 的日志在 stderr，stdout 必须保持纯 JSON-RPC。不要将 shell 欢迎信息插入协议流。
