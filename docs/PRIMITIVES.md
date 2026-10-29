# CUA = 操作 App + 获取 App 信息

只提供可组合的 macOS 原语，不提供切会话、开聊天、发送聊天或其它业务流程。
`find-text` / `click-text` 是通用定位原语，不理解联系人/聊天业务。

## 获取信息

```sh
cua apps --running --windows --json
cua apps --installed --json
cua windows --app com.apple.TextEdit --json
cua info --app com.apple.TextEdit --limit 100 --depth 6
cua state --app com.apple.TextEdit --no-screenshot --query AXTextArea --json
cua ax attributes --app com.apple.TextEdit --element 7
cua ax actions --app com.apple.TextEdit --element 7
cua ax get --app com.apple.TextEdit --element 7 --attribute AXValue
```

`info` 是默认不截图的结构化 state。返回 bundle/PID/activation policy、窗口几何、
前台 App/PID、全局光标、权限；AX 树提供 role/subrole/title/value/description/identifier、
states/actions/frame，及焦点、选中文本。小/离屏窗口也保留在 windows 元数据中。
query/limit/depth 只裁剪展示，不重新编号；`truncated=true` 表示并非完整树。
元素 index 来自最近一次捕获，TTL 120 秒，不能跨刷新持久保存；snapshotId 便于识别刷新。
当前索引表 per-app 共享，不是多客户端会话隔离。`--window` 无匹配时报错，不能悄悄换窗口。
apps 的 installed 指标准安装目录扫描结果，非系统所有可执行文件的穷举。

## 操作

下列 `7`、`WINDOW_ID` 是示意，必须替换为刚读取的真实值。

```sh
cua ax set --app com.apple.TextEdit --element 7 --attribute AXValue --value 'hello'
cua ax focus --app com.apple.TextEdit --element 7
cua ax action --app com.apple.TextEdit --element 7 --action AXPress
cua ax set --app com.apple.TextEdit --element 7 --attribute AXSelectedTextRange \
  --value-json '{"location":0,"length":5}'
cua click --app com.apple.TextEdit --element 7 --strategy ax
cua --activate click --app com.apple.TextEdit --window WINDOW_ID --x 100 --y 80
cua --activate click --app com.apple.TextEdit --x 300 --y 200 --coordinate-space global
```

- 默认后台：不主动激活、不向全局事件流注入。AXFocused 是元素焦点，不是 raise App。
- AXRaise / AXFrontmost / AXMain 必须明确 `--activate`；普通 AX set 只写可写属性。
- click strategy=auto 优先 AXPress；coordinate 显式绕过 AX；ax 不回退。
- x/y 默认窗口内 points，global 是全局屏幕 points，均为左上原点；element 与 x/y 互斥。
- 保留 press-key/type/scroll/drag/set-value/paste/select-text/action 与截图/OCR。
- 背景坐标 click（无 element）拒绝执行；element 回退及 scroll/drag/键盘可 pid 定向投递。
  不同 App 是否响应不保证；App 自身可能激活或移动光标。
- 动作返回 accepted/changed/effect/path/evidence。accepted 不表示业务成功；
  changed=false 或缺省时 effect=unverified。证据仅覆盖短暂观察中的目标属性/窗口，
  不排除异步或不可观测变化。不会因没看到变化自动再点一次。
- path 区分 ax-press / ax-set / ax-action、pid 或 global 输入；AX set 还提供值回读。
- clickText 兼容旧 `{match}`，没有效果保证。MCP 原工具保持兼容，新 AX 使用 CLI/RPC。
- activate 是当前引擎共享策略，应串行使用；CLI 每次默认复位 false。
  显式前台操作不自动恢复原 App。证据可能含文本，按敏感数据处理。

## 验证记录（2026-10-29）

执行 `swift build --scratch-path .build-primitives` 与 `swift test --scratch-path .build-primitives`，均 exit 0。
最终全套 65 个测试：64 通过，1 个 opt-in live 默认跳过，0 失败（Service 18 / Engine 27 / Core 2 / Client 18）。
纯测试覆盖 bounds/index 保留、AX 名称/可写类型/激活限制、无变化未验证语义、CLI 参数和旧 payload。
额外只读探针：

```sh
SWIFTCUA_LIVE_PRIMITIVES=1 SWIFTCUA_TRACE_CURSOR=1 \
  swift test --scratch-path .build-primitives --filter PrimitiveLiveTests
```

直接实例化新 SkyEngine，没有替换/重启已安装服务，也没有发送输入事件、截图、启动或激活 App。
14:10:35 的只读轮次通过（0.674 秒）：

| App | PID | 窗口 ID | root role | 根属性数 |
|---|---:|---:|---|---:|
| TextEdit | 50489 | 20311 | AXWindow | 29 |
| Finder | 1542 | 19569 | AXWindow | 30 |
| WeChat | 87982 | 20622 | AXWindow | 28 |

三者均可读取结构化 state、AXRole、属性及动作列表；limit=12/depth=2 时 truncated=true。
权限 accessibility/screenRecording 均 true。前台原本已是 WeChat，前后 PID 都为 87982；
光标前后均 `(2206.36328125, -479.203125)`。从未切换 WeChat 会话或发消息。
前一只读轮次前台不变，但光标从 `(1710.75390625,-1341.046875)` 到
`(1708.73828125,-1344.35546875)`，因此严格光标断言失败；不能把那轮宣称无光标变化。
探针无输入路径，外部用户/App 活动仍可能影响观测；保留该失败说明而非隐藏。
为避免改动用户现有文档，未实机验证 AX 写入、焦点或鼠标键盘效果；这些仅有纯逻辑/策略测试。
