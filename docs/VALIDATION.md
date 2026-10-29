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
