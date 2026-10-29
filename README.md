# SwiftCUA

[![ci](https://github.com/V1ki/swift-computer-use/actions/workflows/ci.yml/badge.svg)](https://github.com/V1ki/swift-computer-use/actions/workflows/ci.yml)

**A from-scratch Swift 6 reimplementation of macOS computer-use tooling, built from a clean-room
reverse-engineering study of the `Codex Computer Use.app` service — with a drop-in
`@oai/sky`-compatible JS bridge and an MCP server.**

> 中文简介：本项目对一个 macOS 上的 Computer Use 后台服务做了完整逆向（App 结构 / IPC 协议 /
> 权限与锁屏安全模型 / AX·截图·输入引擎），然后用 Swift 6 从零重写了一套功能等价的实现：
> 常驻服务 + `cua` 命令行 + MCP server + 与 `@oai/sky` 同形的 JS 客户端。
> 与 OpenAI 无任何关系，不包含其代码，不包含任何私有 API 调用。

---

## 1. 能力一览

| 组件 | 说明 |
|---|---|
| `CUAService` | `LSUIElement` 后台服务：AF_UNIX socket、JSON-RPC 2.0（4B LE 长度前缀）、按会话授权 App、权限门 |
| `CUAEngine` | 无障碍树抓取（AXUIElement）+ 元素索引表、ScreenCaptureKit 截图、CGEvent/AX 输入注入、应用与窗口枚举 |
| `cua` | 命令行：`ping`/`apps`/`windows`/`state`/`click`/`press-key`/`type`/`scroll`/`set-value`/`drag`/`paste`/`select-text`/`action`/`screenshot`/`doctor`/`session`/`call` |
| `cua mcp` | stdio MCP server，16 个工具（含 `find_text` / `click_text`） |
| `@swiftcua/sky` | Node 客户端：`sky.list_apps()`、`sky.get_app_state()` … 与原 `@oai/sky` 同形，另有 `find_text`/`click_text` |
| `swiftcua-mcp` | Node MCP server，提供 cua_repl 风格 `js` / `js_reset` / `turn_ended` 工具 |

## 2. 快速开始

```bash
git clone https://github.com/V1ki/swift-computer-use
cd swift-computer-use

make build        # swift build
make test         # 单元测试（不需要任何系统权限）
make js-test      # Node 兼容层测试

make install      # 组装并签名 SwiftCUA.app → ~/Applications + LaunchAgent
```

首次安装后授权（一次性）：

1. 打开「系统设置 → 隐私与安全性 → 屏幕录制」，添加/勾选 `SwiftCUA.app`
2. 打开「系统设置 → 隐私与安全性 → 辅助功能」，添加/勾选 `SwiftCUA.app`
3. `launchctl kickstart -k gui/$(id -u)/dev.v1ki.swiftcua.service`

助手：`./scripts/open-permissions.sh` 会直接打开这两个设置面板（授权仍需手点）。

验证：

```bash
~/Applications/SwiftCUA.app/Contents/MacOS/cua doctor
~/Applications/SwiftCUA.app/Contents/MacOS/cua ping
~/Applications/SwiftCUA.app/Contents/MacOS/cua apps
~/Applications/SwiftCUA.app/Contents/MacOS/cua state --app com.apple.Safari --screenshot-out /tmp/safari.jpg
```

> 签名身份：`scripts/build-app.sh` 会自动挑选钥匙串里的第一个 *Apple Development* 身份；
> 也可用 `CUA_SIGN_IDENTITY="Apple Development: ..." make app` 指定。
> 用固定身份签名，TCC 授权才能在重编译后保留；ad-hoc 签名每次重建都会被系统当成新 App。

## 3. 用 JS 驱动（兼容 `@oai/sky`）

```js
// 以前：import { sky } from "@oai/sky";
import { sky } from "@swiftcua/sky";   // 换成这一行即可

const apps = await sky.list_apps({ includeWindows: true });
const state = await sky.get_app_state({ app: "com.apple.Safari" });
console.log(state.text);               // 带索引的无障碍树

await sky.click({ app: "com.apple.Safari", elementIndex: 12 });
await sky.type_text({ app: "com.apple.Safari", text: "hello" });
await sky.press_key({ app: "com.apple.Safari", key: "Control_L+l" });
```

安装：

```bash
cd js && npm link          # 或 npm install /path/to/swift-computer-use/js
```

## 4. MCP 集成

把服务暴露给任意 MCP 客户端（Codex / Claude Desktop / 其它）：

```json
{
  "mcpServers": {
    "swiftcua": {
      "command": "$HOME/Applications/SwiftCUA.app/Contents/MacOS/cua",
      "args": ["mcp"]
    }
  }
}
```

或使用 Node 版（额外提供 `js` 沙箱工具，和原 cua_repl 同形）：

```json
{
  "mcpServers": {
    "swiftcua-repl": {
      "command": "node",
      "args": ["/path/to/swift-computer-use/js/bin/mcp.mjs"]
    }
  }
}
```

工具清单与参数见 [`js/README.md`](js/README.md) 与 `cua mcp` 的 `tools/list`。

## 4.5 微信这类 App 怎么控制

> 完整研究见 [`re/05-ax-less-apps.md`](re/05-ax-less-apps.md)。

1. **先激活再读 AX**：很多国产 App（微信、部分 Electron/CEF 壳）是「懒 AX」——不在前台时
   只暴露菜单栏。SwiftCUA 的 `getAppState`/`findText` 检测到根不是 `AXWindow` 会自动激活重抓。
2. **AX 可用就用语义操作**：微信激活后有会话列表（`list "会话"`，每行一个 `staticText`）、
   消息列表、输入框、发送按钮，可 `click --element N` / `click-text --text 通讯录`。
3. **AX 不可用再退像素**：`capture_screenshot` + `find_text`（Vision OCR）拿窗口相对坐标，
   `click --x --y` / `click_text` 点击；键盘快捷键（`press_key`）优先于坐标。
4. **发消息这类不可逆动作**要人工确认，`发送` 按钮在输入框为空时是 `disabled`，可作安全断言。

```bash
cua state  --app com.tencent.xinWeChat                  # 自动激活并返回完整树
cua find-text  --app com.tencent.xinWeChat --text 通讯录
cua click-text --app com.tencent.xinWeChat --text 通讯录   # 切到通讯录页
cua find-text  --app com.tencent.xinWeChat --text 搜索 --ocr-only   # 强制 OCR 定位
```

## 5. 逆向报告

| 报告 | 内容 |
|---|---|
| [`re/01-bundle-and-binary.md`](re/01-bundle-and-binary.md) | App bundle 结构、6 个 Mach-O、签名/公证、符号面、Sparkle/Statsig、BUILD.bazel 泄露的模块划分 |
| [`re/02-protocol.md`](re/02-protocol.md) | 客户端↔服务协议：4B LE + JSON-RPC 2.0、ping 握手、14 帧实测、11 个方法参数形状、MCP 工具 schema |
| [`re/03-security-model.md`](re/03-security-model.md) | TCC 权限矩阵、连接级签名/审计校验、会话与 Always-allow 落盘、锁屏授权插件与 Ctrl-Cmd-Q 回锁 |
| [`re/04-engine-internals.md`](re/04-engine-internals.md) | 截图（SkyLight/SCScreenshotManager）、AX 树（公开 API + 私有 AccessibilitySPI）、输入注入（CGEventPostToPid）、AX 文本格式 |
| [`re/05-ax-less-apps.md`](re/05-ax-less-apps.md) | 懒 AX / 无 AX 应用的 AX 可用性矩阵、激活重试、OCR 兜底、快捷键与坐标控制策略 |

> `re/raw/` 里的原始 dump 有数百 MB，未入库；已入库的只有 `re/raw/*/run.sh` 等小体积复现脚本（见 [re/README.md](re/README.md)）。

## 6. 验证状态

- **测试**：40 个 Swift 单元测试 + 21 个 JS 测试 + `scripts/smoke.sh` 端到端冒烟，全部通过。
- **协议**：安装版服务 ping / list_apps(327) / 会话授权 TOML / 权限门错误码实测通过。
- **引擎**：开发版服务（继承终端 TCC）实测 AX 树 1233 元素、`--query` 过滤、窗口映射与 2560×1410 JPEG 截图。
- **待用户授权**：安装版服务的屏幕录制/辅助功能授权、真实鼠标键盘注入（会抢占前台，未自动执行）。

完整证据见 [`docs/VALIDATION.md`](docs/VALIDATION.md)。

## 6. 架构与协议

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) —— 进程图、模块边界、四条引擎管线、与原实现的差异
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) —— 完整线协议：分帧、握手、方法表、错误码、超时
- [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) —— `@oai/sky` 方法映射与已知差异
- [`docs/VALIDATION.md`](docs/VALIDATION.md) —— 本机实测记录（测试、AX 树、截图、安装状态）

## 7. 安全模型

- socket 权限 `0600`，只允许同用户进程；可选的对端签名校验（`--require-peer` + `config.json` 白名单）。
- 每次会话按 App 授权，落盘 TOML；`autoAuthorizeApps` 可关闭以要求显式授权。
- 不联网、无遥测、自动更新关闭；截图与 AX 文本只走本机 socket。
- 刻意**不**实现锁屏操作与提权自动化（原服务通过 `/Library/Security/SecurityAgentPlugins` 做到这一点，风险过高）。

## 8. 已知差异

| 项 | 原服务 | SwiftCUA |
|---|---|---|
| 私有 API | SkyLight / WindowServerSPI / AccessibilitySPI | 仅公开 API |
| 锁屏操作 | 支持（授权插件） | 不支持 |
| 协议字节兼容 | — | 否（仅分帧一致） |
| App 发现 | Spotlight MDQuery | NSWorkspace |
| 更新/遥测 | Sparkle + Statsig | 无 |

## 9. 目录结构

```
Sources/CUACore/     协议、模型、帧、错误码、路径
Sources/CUAEngine/   AX 树、截图、输入、应用/窗口目录
Sources/CUAService/  socket 服务、鉴权、会话、路由
Sources/CUAClient/   cua CLI + MCP server
js/                  @swiftcua/sky + swiftcua-mcp（零依赖）
re/                  逆向报告（raw dump 不入库）
docs/                架构、协议、兼容性
scripts/             构建、签名、安装、卸载、开发服务
```

## 10. 开发

```bash
swift build && swift test            # 主包
cd js && node --test test/           # JS 桥
./scripts/dev-service.sh             # 前台跑服务（隔离 ~/.devhome）
```

## 11. 故障排查

| 现象 | 处理 |
|---|---|
| `cua doctor` 报 socket 不存在 | `launchctl kickstart -k gui/$(id -u)/dev.v1ki.swiftcua.service`，看 `~/Library/Logs/SwiftCUA/service.err.log` |
| `permissionMissing: ScreenRecording` | 系统设置里勾选 `SwiftCUA.app`，然后重启服务 |
| `elementIndexStale` | 重新 `get_app_state`，索引表随每次捕获重建 |
| 右键菜单/弹窗拿不到 | 弹窗是独立窗口，先 `list_windows` 找到它再定向操作 |

## 12. License / 免责声明

MIT（见 [LICENSE](LICENSE)）。
本项目仅用于学习与研究；逆向部分只做只读分析，未修改、未分发原 App 的任何代码或资源。
"Codex"、"OpenAI" 是其各自权利人的商标，本项目与其无隶属或背书关系。
