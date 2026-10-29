# 逆向报告索引

本目录是 Codex Computer Use 服务 App 的**只读**逆向分析结果。所有结论都标了证据等级：

- `[二进制]` 直接来自 Mach-O 符号 / 反汇编 / 字符串 / 段数据
- `[字符串]` 仅来自字符串或 plist 等静态资源
- `[实测]` 本机只读观测（日志、`ls`、`launchctl`、socket 探测）
- `[JS]` 来自宿主 App 内明文的 `@oai/sky` JS 源码
- `[推测]` 合理推断，报告里会说明依据

| 报告 | 内容 |
|---|---|
| [01-bundle-and-binary.md](01-bundle-and-binary.md) | bundle 结构、6 个 Mach-O、签名/公证、符号面、Sparkle/Statsig、模块划分 |
| [02-protocol.md](02-protocol.md) | 客户端↔服务协议：分帧、握手、方法序列化、错误、MCP 工具 schema |
| [02-protocol-state-machine.md](02-protocol-state-machine.md) | 连接、授权、业务请求与拒绝时序 |
| [03-security-model.md](03-security-model.md) | TCC 权限矩阵、连接级鉴权、会话授权、锁屏授权插件与回锁 |
| [04-engine-internals.md](04-engine-internals.md) | 截图、AX 树、输入注入、文本渲染格式、公共 API 等价实现 |
| [05-ax-less-apps.md](05-ax-less-apps.md) | 懒 AX / 部分 AX / 无 AX 应用：AX 可用性矩阵、激活与开关的实测陷阱、控制策略、OCR 与快捷键 |
| [06-background-and-preview.md](06-background-and-preview.md) | 后台执行与预览：SCStream 触发系统共享面板、CGEventPostToPid 能力矩阵、原版合成焦点/PIP 证据与公开 API 边界 |

## 原始证据

`re/raw/` 里的完整 dump（`nm`、反汇编、strings、module cache 等）数百 MB，未入库。
已入库的只有小体积复现脚本：

```
re/raw/bundle/run.sh          # bundle/签名/符号/字符串采集
re/raw/protocol/probe_socket.py       # 最小 AF_UNIX 探测（只读）
re/raw/protocol/probe_mcp_schema.py   # MCP tools/list 元数据探测
re/raw/engine/run.sh          # 引擎侧符号/字符串采集
re/raw/engine/PublicAPIExamples.swift # 等价的公开 API 示例（可 typecheck）
re/raw/security/run.sh + derive.py     # 权限/锁屏/插件证据派生
```

运行前提：目标 App 仍安装在
`~/.codex/computer-use/Codex Computer Use.app`。脚本只读，不修改、不终止任何进程。
