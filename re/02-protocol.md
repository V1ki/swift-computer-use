# Codex Computer Use：客户端 ↔ 服务端协议逆向

## 0. 结论与证据边界

调查时间：2026-10-29（Asia/Shanghai）；目标 `@oai/sky 0.7.8`、`@oai/cua 0.2.6`、`@oai/cua-repl 0.1.0`，运行中服务 PID 14867。只读检查系统安装物；仅在本报告与 [原始证据目录](<raw/protocol/>) 写入；无 git 操作、无安装、无进程 kill、无输入注入、无截图。

**核心结论：**

1. **[JS源码] mac 使用 AF_UNIX 字节流上的 `UInt32LE bodyLength + UTF-8 JSON-RPC 2.0`，不是 protobuf / CBOR / msgpack / NDJSON。** 8 MiB 是 JSON body 上限；TCP/Unix read 边界不是帧边界。
2. **[JS源码] socket 方法是 `ping` 和 `request`。** `setup/execute/drag_start/drag_move/drag_end` 属于上一层隔离 REPL → trusted Sky service RPC，不可直接当作 socket method。
3. **[JS源码] 握手版本精确匹配 `CodexComputerUseIPC-5`；每次业务请求携带 `requestType` 和嵌套 `request`。** 动作是 Swift Codable 枚举风格的对象，例如 `action.click.at.elementID._0 = "7"`。
4. **[实测] 普通 Python 可以完成 socket connect，但在发送任何业务字节之前就收到 EOF。** 同时刻服务日志明确 `Sender process is not authenticated`，因此真实业务通路未打通，未发送 ping/list_apps。见 [探测日志](<raw/protocol/probe-socket-run.log>)、[服务日志:30](<raw/protocol/service-auth-log.txt#L30>)。
5. **[实测·离线] FakePipe 拦截官方客户端的 14 个写出帧，覆盖全部 11 个目标方法及两种定位方式。** 这是序列化实测，不是服务执行成功，见 [帧集](<raw/protocol/offline-serialization-frames.json>)。
6. **[实测] 独立 node_repl 仅执行 MCP initialize/tools/list，取得完整 schema；未调用 JS、reset、turn_ended 或其他工具。** [schema](<raw/protocol/mcp-tools-list.json>)。

标记：`[JS源码]`=发布 JS 实现（即便 minified）；`[二进制证据]`=Mach-O strings/nm/内嵌文本，不能单独证明运行分支；`[实测]`=本次运行观察，离线与在线严格区分；`[推测]`=解释性推断。

发布 JS 为**明文、单行压缩、变量名缩短**，并非全量未压缩 TS 源码；全包遍历未见 `.map`。完整文件清单见 [inventory](<raw/protocol/sky-file-inventory.txt>)。已逐项分析 mac 的 transport/client/policy/wrappers 与公共 service/sky 层；未宣称完整逆向 Linux/Windows 实现。原始 JS 无改动副本及 SHA256 见 [manifest](<raw/protocol/source-manifest.json>)；`*.readable.txt` 只是字符串外 `{ } ;` 后插入换行，不是语义重写。

## 1. 三层协议，不能混用

```text
Codex plugin hooks / MCP client
    | stdio MCP：逐行 JSON-RPC 2.0（实测独立 runtime）
cua-repl launcher -> node_repl (persistent JS + privileged host)
    | nodeRepl.rpc("sky", {type:"setup" | "execute", ...})
    | trusted service @oai/sky/service::handleRpc
    | （nativePipe 的实际 OS 连接委托给 privileged host）
MacComputerUseClient -> MacNativePipeTransport
    | AF_UNIX + uint32 LE length + JSON-RPC 2.0
SkyComputerUseService
```

### 1.1 隔离 JS → trusted Sky service

[JS源码] [sky proxy](<raw/protocol/sky-sky.js.readable.txt#L13-L75>) 与 [service dispatcher](<raw/protocol/source-service.js.readable.txt>)：

| 请求 | 应答 / 处理 |
|---|---|
| `{type:"setup"}` | `{target:"mac", methods:[...]}`；只暴露 client 自有函数属性 |
| `{type:"execute", method:"list_apps", args:[]}` | 调用 `client[method](...args)`，返回方法结果 |
| `{type:"execute", method:"click", args:[{app,element_index,...}]}` | 同上，非 socket action 形状 |
| `{type:"drag_start", handle_id, point}` | 仅 Linux：创建/保存 drag handle |
| `{type:"drag_move", handle_id, point}` | 对已保存 handle 调 `move_to` |
| `{type:"drag_end", handle_id}` | 调 `end`，删除 handle |

mac `setup` 返回 `list_apps/get_app_state/click/drag/paste/perform_secondary_action/press_key/scroll/select_text/set_value/type_text`。只有 `SKY_ENABLE_AUDIO=1` 才增加音频方法。mac 不使用三段 drag handle。

## 2. socket、启动和身份认证

### 2.1 路径和启动回退

[JS源码] [native transport:18–113](<raw/protocol/sky-native-pipe.js.readable.txt#L18-L113>)：

- 默认 socket：`~/Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC/computeruse.sock`。
- `globalThis.nodeRepl.env.SKY_CUA_SERVICE_NATIVE_PIPE_PATH` 非空时覆盖；不是任意 `process.env` 直接覆盖。
- 必须有 trusted `nodeRepl.nativePipe.createConnection`；普通 Node 无该对象会报 transport unavailable。
- 先用 250ms 预算连接/握手；可恢复连接失败会请求启动服务，之后再给 5000ms。
- 若存在 `NODE_REPL_HOST_SERVICES_PIPE_PATH`，连接 host-services pipe，发同样长度帧格式的：
  ```json
  {"id":0,"jsonrpc":"2.0","method":"ensureService","params":{"service":"computer-use"}}
  ```
  连接/等待应答各有 5 秒超时，结果只检查存在 `result`，失败读取 `error.message`，最终关闭此辅助连接。
- 否则 `nodeRepl.launchServices.openApplication`：优先 `SKY_CUA_SERVICE_PATH`；次选 `CODEX_HOME/computer-use/Codex Computer Use.app`（必须存在）；最后 bundle identifier `com.openai.sky.CUAService`。
- 本次 probe **不实现启动回退、不重试、不触碰辅助锁屏 socket**。

`/tmp/com.openai.sky.CUAService/LockScreenLoginAuthorization.sock` 在 [server strings:30411](<raw/protocol/server-strings.txt#L30411>) 存在，并邻接 `LockScreenLoginAuthorizationSocketServer`；mac JS 没有连它。它是独立锁屏授权通路，不能据此推断其帧协议与 computeruse.sock 相同。

### 2.2 认证不在 JSON secret/token 中

[JS源码] 没有 nonce、password、bearer token 或客户端 HMAC 握手。第一次正常写出是版本 ping。

[二进制证据] [socket/server strings:30280–30360](<raw/protocol/server-strings.txt#L30280-L30360>) 包括：

- `ComputerUseIPCJSONRPCSocketConnection`、`maximumFrameSize`、`processFrame`、`ioTimeout`；
- `senderAuthorization`、`senderContextResolver`、`prepareForAuthenticatedRequest`；
- `LOCAL_PEERTOKEN failed errno=`、`invalid peer token length:`；
- `relay_without_trusted_ancestor`、`untrusted_parent`；
- parent/responsible 的 team ID、signing ID、bundle ID、executable 诊断字段。

[nm](<raw/protocol/server-nm.txt>) 有 `_SecCodeCopyGuestWithAttributes`、`_audit_token_to_pid`、`_xpc_dictionary_get_audit_token`；[demangled symbols](<raw/protocol/server-protocol-symbols-demangled.txt>) 有 `ComputerUseIPCSenderAuthorization.ProcessIdentity`、`ComputerUseIPCSenderContext.parentIdentity/responsibleIdentity`。

[实测] 08:22:05 Python `connect()` 成功，250ms 被动 `recv` 立即返回空 bytes；服务 PID 14867 在 08:22:05.018 记录认证失败。**拒绝点是建立 socket 后、应用 JSON 请求前；未收到 `-10000` JSON 错误帧。**

[推测] 内核 peer audit token → 进程签名/parent/responsible 授权 → 接受帧处理的安全链与上述观察吻合。尚未反汇编确定 allowlist 的精确 signing identifiers、trusted ancestor 深度、relaxed 变体条件。不能把 `connect success` 写成“协议已可访问”，也不能仅凭日志断言究竟是 team ID 还是 parent check 失败。

## 3. 帧字节布局与消息形状

### 3.1 帧

[JS源码] [encode/decode:172–205](<raw/protocol/sky-native-pipe.js.readable.txt#L172-L205>)：

```text
偏移        0          1          2          3          4 ... 4+N-1
         +----------+----------+----------+----------+------------------+
内容     | N & 0xff | N >> 8   | N >> 16  | N >> 24  | UTF-8 JSON body  |
         +----------+----------+----------+----------+------------------+
         <------------- UInt32 little endian ------> <----- N 字节 ---->

N = UTF-8 字节数（不是 JS UTF-16 length），不包含 4-byte header。
N <= 8,388,608；无 magic、delimiter、CRC、额外 type byte 或附件区。
```

拆包器累计 buffer，少于 4 bytes 等待；header 完整但 payload 不足则保留；可一次提取多个帧，剩余尾部留待下一次。长度超限立即报错。零长 body 不被 frame 层禁止，但 JSON.parse 随后失败。

[实测·离线] ping body 恰好 94 bytes，header=`5e 00 00 00`：

```json
{"id":1,"jsonrpc":"2.0","method":"ping","params":{"clientApiVersion":"CodexComputerUseIPC-5"}}
```

### 3.2 握手与版本

[JS源码] 客户端从 id=1 起递增，成功响应形状：

```json
{"id":1,"jsonrpc":"2.0","result":{"serverApiVersion":"CodexComputerUseIPC-5"}}
```

此响应是按客户端读取要求重建的**期望形状，未在线收到**。`serverApiVersion !== clientApiVersion` 抛 mismatch，非功能协商。`-10013 incompatibleClientVersion` 或本地 mismatch 不进入服务启动重试。服务端二进制也有 `CodexComputerUseIPC-5`；另见 `CodexComputerUseNativeBridge-1`，没有证据说明后者是当前 socket 握手版本。

### 3.3 业务请求、响应、事件

[JS源码] 每个业务请求都包装为：

```json
{
  "id":2,
  "jsonrpc":"2.0",
  "method":"request",
  "params":{
    "clientApiVersion":"CodexComputerUseIPC-5",
    "codexTurnMetadata":{"session_id":"...","turn_id":"..."},
    "deadlineUnixMilliseconds":1793233550566,
    "requestType":"ComputerUseIPCListAppsRequest",
    "request":{}
  }
}
```

- `codexTurnMetadata`：per-call `codexMetadata` 优先，其次 client option，最后 trusted `nodeRepl.requestMeta["x-codex-turn-metadata"]`；无值则 JSON.stringify **省略字段**，null 则保留 null。普通对象直接通过；字节/字符串经 Buffer UTF-8→JSON.parse。JS 不规定 metadata 内部 schema，例子不能视作完整字段要求。
- `deadlineUnixMilliseconds=Date.now()+timeoutSeconds*1000`，不是秒；进入串行队列实际发送时才计算。
- 成功：`{"id":2,"jsonrpc":"2.0","result":...}`。
- 失败：`{"id":2,"jsonrpc":"2.0","error":{"code":-10000,"message":"..."}}`；此处为 schema 示例，非本次线上返回。
- **该 mac socket 客户端无第三类事件分发器。** 入站必须有 number id、`jsonrpc:"2.0"`、result/error 二者恰好一个。无 id 的 notification/event 被视为 invalid response 并终止连接。未知但格式合法 id 的应答被忽略。
- 不支持 JSON-RPC batch 数组；error.data 即使存在也不传播。服务二进制另有 XPC foreground subscription，不等同于本 JS socket 支持推送。

## 4. mac 完整 method 序列化表

[JS源码] [client:10–221](<raw/protocol/sky-client.js.readable.txt#L10-L221>)、各 mac wrapper；[实测·离线] [完整写出帧](<raw/protocol/offline-serialization-frames.json>)。

表中 `A` 为 app 字符串，`E` 为整数 element_index 转换后的十进制字符串；所有内容均处于 `params.request`，不是 JSON-RPC 顶层 params。`?` 表示输入 undefined 时该字段整个省略（下列是结构模板，非可直接复制的 JSON）。

| sky 方法 / 输入 | requestType | 真正 request 对象 |
|---|---|---|
| `list_apps()` | `ComputerUseIPCListAppsRequest` | `{}` |
| `get_app_state({app,disableDiff?})` | `ComputerUseIPCAppGetSkyshotRequest` | `{"app":A,"disableDiff":bool?}` |
| `click({app,element_index? 或 x/y,click_count?,mouse_button?,key?,duration?})` | `ComputerUseIPCAppPerformActionRequest` | `{"app":A,"action":{"click":{"at":AT,"clickCount":1,"key":string?,"duration":number?,"mouseButton":0}}}` |
| `press_key({app,key,duration?})` | 同上 | `{"app":A,"action":{"pressKey":{"_0":key,"duration":number?}}}` |
| `type_text({app,text})` | 同上 | `{"app":A,"action":{"type":{"_0":text}}}` |
| `scroll({app,direction,element_index? 或 x/y,pages?})` | 同上 | `{"app":A,"action":{"scroll":{"at":AT,"direction":"up/down/left/right","pages":1}}}` |
| `set_value({app,element_index,value})` | 同上 | `{"app":A,"action":{"setValue":{"elementID":E,"value":value}}}` |
| `drag({app,from_x,from_y,to_x,to_y})` | 同上 | `{"app":A,"action":{"drag":{"from":[from_x,from_y],"to":[to_x,to_y]}}}` |
| `paste({app,text,format})` | 同上 | `{"app":A,"action":{"paste":{"text":text,"format":format}}}` |
| `select_text({app,element_index,text,prefix?,suffix?,selection_type?})` | 同上 | `{"app":A,"action":{"selectText":{"elementID":E,"text":text,"prefix":string?,"suffix":string?,"selection":"text"}}}` |
| `perform_secondary_action({app,element_index,action})` | 同上 | `{"app":A,"action":{"performSecondaryAction":{"action":action,"elementID":E}}}` |

### 4.1 最容易写错的字段

**定位 AT 是 Swift enum 风格，不是 `{x,y}` 或 `{element_index}`：**

```json
{"elementID":{"_0":"7"}}
```

或：

```json
{"coordinate":{"_0":[123.5,45]}}
```

`setValue/selectText/performSecondaryAction.elementID` 则是裸字符串 `"7"`，**不套 `_0`**。`drag.from/to` 是裸 `[x,y]`，**不套 `coordinate`**。

- `element_index` 通过 wrapper 改名为 `elementIndex`，client 要求 `Number.isInteger` 后 `String(...)`。不验证非负或 safe integer。若 elementIndex 非 null，它优先于 x/y；否则 x/y 必须有限数。
- 坐标为 app-window screenshot 坐标的文档语义；JS 只验证 finite 并原样数值化，**没有缩放、DPI 或屏幕偏移转换**。
- click 默认 clickCount=1、mouseButton=0；left/l→0，right/r→1，middle/m→2；也接受数字 0/1/2。clickCount 在此层不作整数校验。
- click.key 和 pressKey._0 是**原样 chord 字符串**，不是 modifier bitmask 或数组；pressKey 只检查 trim 后非空，发送仍保留原字符串。`+` chord、keysym 名称/别名解析在服务侧，不应凭 JS 臆测完整 alias 表。
- duration 单位为秒；直接 sky 只验证有限数，不在此层禁止负值。`cua.getApp(...).click/pressKey` 的 durationMs 由上层转换为秒。
- scroll 默认 pages=1，必须 finite 且 >0；u/d/l/r 归一化到 up/down/left/right。
- select_text 的 selection_type 映射为 selection，默认 `text`；before/after 等字符串没有在此 client 层进一步验证。
- paste format（发布 API 文档为 text/md/html）原样传递；上层 app-bound `.paste(text)` 默认 text，但底层 sky.paste 自身没有默认 format。
- **mac 上完全没有 screenshotId/screenshot_id 字段。** 同版本 cua 的 Windows binding 会缓存并附带 screenshotId，mac binding 不会。不能跨 target 偷套字段；mac 状态关联依赖服务 session/最新 skyshot，而非本客户端显式携带 ID。

### 4.2 policy 前置请求与返回值

[JS源码] 对除 list_apps 以外这些 app-scoped 操作，public sky wrapper 先执行 [policy](<raw/protocol/sky-computer-use-policy.js.readable.txt#L14-L89>)：

1. `requestType=ComputerUseIPCAppPolicyRequest, request={app:原输入}`。
2. 根据响应 `decision`（allowed/denied/forbidden）与 `target` 处理。
3. 调 trusted `nodeRepl.createElicitation` 要求 app approval；非 accept 不发动作。
4. 将后续 request.app 改为 `target.appPath`，因此通常是规范化绝对 app 路径，而非最初 bundle ID/名字。

低层 MacComputerUseClient 支持 `ComputerUseIPCAppStartRequest {app}`，但 mac sky public method 表未暴露 start_app。还有 start/stop audio request types；本任务未调用。

响应解释：

- `listApps()` 低层期待数组；public wrapper 输出 `{id:bundleIdentifier ?? displayName ?? "unknown",displayName,isRunning,lastUsedDate?,useCount?}`。
- `getAppState()` 低层响应使用 `skyshot.text`、可选 `skyshot.screenshot.url`、`appSpecificInstructions`、`app.bundleIdentifier`。public 输出 `{app, screenshot:null|{url}, text}`；缺 skyshot/text 会报错；同 app instructions 仅首次附加，Numbers 特殊跳过。
- 动作 public wrapper await 后不返回低层 result，表现为 undefined。不能由此断言服务 result 是 null 还是 `{}`，本次没有在线动作响应。

## 5. 时序、超时与错误传播

[JS源码] [transport](<raw/protocol/sky-native-pipe.js.readable.txt#L114-L266>)：

- client 按 apiVersion 缓存 transport promise；同版本复用一条连接。已关闭 transport 在下一次调用重建；失败 promise 从 map 删除。
- 连接循环每 100ms 重试一次；ping timeout=min(1000ms,剩余预算)，至少 1ms。
- 业务默认 timeoutSeconds=120；per-call 可覆盖。所有业务 request 以 promise 链**串行化**；前一个失败被吞作队列栅栏，不阻断后一个排队任务。
- timeout 定时器到期：设置 transport closed、reject 所有 pending、清空 map、end socket；后续请求可能重连，**不会自动重放已写出的动作**。
- socket error / close 同样 reject 所有 pending。close 文本 `Sky Computer Use native pipe closed before response`。
- JSON.parse、frame 超限、invalid response 报错后 end。write 同步失败只删除该 pending 并 reject。
- valid error → `SkyComputerUseError`，保留 code/message，errorName 从下表映射；request=null、requestType=`jsonRPC`，不是原始 requestType。未列 code 映射为 `jsonRPCError`。
- 不是每个网络错误都统一包成 transport error：socket error/close 可以是普通 Error；启动阶段会包装 cause。

### 错误码（客户端完整 ServerErrorCode）

[JS源码] [errors](<raw/protocol/sky-errors.js.readable.txt>)；这些是客户端定义，不代表本次逐项触发过。

| code | errorName | code | errorName |
|---:|---|---:|---|
| -10000 | senderProcessNotAuthenticated | -10011 | noActiveSession |
| -10001 | couldNotGetRequestData | -10012 | userStoppedSession |
| -10002 | couldNotGetRequestTypeName | -10013 | incompatibleClientVersion |
| -10003 | couldNotResolveRequestType | -10014 | permissionsPending |
| -10004 | unhandledEvent | -10015 | blockedURL |
| -10005 | unknownError | -10016 | userIntervened |
| -10006 | appNotAllowed | -10017 | couldNotGetSenderPID |
| -10007 | runningApplicationNotFound | -10018 | ambiguousApp |
| -10008 | accessibilityError | -10019 | couldNotGetBootstrapPort |
| -10009 | permissionsNotGranted | -10020 | screenLocked |
| -10010 | invalidApp | | |

[二进制证据] 字符串还包括 `Method not found`、`Response exceeds maximum frame size`、`Request deadline exceeded`，但本次没有建立这些消息对应数值 code 的可靠映射；不把标准 JSON-RPC 的 -32601/-32602 等当作已验证值填入。

## 6. 二进制交叉验证与 protobuf 排除范围

使用 `strings -a`、`nm -a`、`xcrun swift-demangle`，原始输出见 [strings](<raw/protocol/server-strings.txt>)、[nm](<raw/protocol/server-nm.txt>)、[相关 demangled symbols](<raw/protocol/server-protocol-symbols-demangled.txt>)、[关键词摘录](<raw/protocol/server-keyword-excerpts.txt>)。

| JS 结论 | 二进制证据 | 判定 |
|---|---|---|
| JSON-RPC socket | ComputerUseIPCJSONRPCSocketConnection；jsonrpc；socket frame 错误文本 | 一致 |
| IPC-5 | CodexComputerUseIPC-5 | 一致 |
| 参数版本/deadline | clientApiVersion/serverApiVersion/deadlineUnixMilliseconds | 一致 |
| requestType 动态分派 | ComputerUseIPC*Request 类型、encode(to:)/init(from:) Codable 符号 | 一致 |
| peer 身份认证 | LOCAL_PEERTOKEN、Security/audit imports、senderAuthorization | 一致；具体 allowlist 待解 |
| Swift 枚举形状 | `Invalid number of keys found, expected one.` 与 Codable 类型符号 | 支持但非独立字节证明 |

SwiftProtobuf/OAIProtobuf 确实存在，尤其 `protobuf_analytics_events.v1.*` 大量埋点类型；同时有 Google_Protobuf_FileDescriptorProto 类型。**类型存在不等于嵌入了该服务协议 descriptor，更不等于 socket 用 protobuf。**

[二进制证据] [扫描结果](<raw/protocol/protobuf-scan.json>)：SwiftProtobuf resource bundle 仅发现 Info.plist、签名 CodeResources、PrivacyInfo.xcprivacy；未发现 `.proto` 文件名的 NUL 结尾字符串，也未发现 `0x0a + 单字节长度 + *.proto` 的 descriptor-name 候选。未定位到可可靠 decode 的 FileDescriptorProto payload，因此**没有伪造 descriptor dump**。该扫描是启发式，不排除压缩/拆分/无 name 或更复杂编码的 descriptor；目前无迹象要求用它解释此 mac JS socket。

另外二进制有 XPC/AppleEvent 传输、Codex appserver JSONRPCLineBuffer、NativeBridge-1 等不同机制；这些不冲突，不能把 line buffer 当作本 socket 用换行帧的证据。

## 7. MCP 工具、全局对象与 turn_ended 链路

### 7.1 MCP launcher 与实际 schema

[JS源码] [launcher](<raw/protocol/cua-repl--lib--js--oai_js_cua_repl--src--launch.js.readable.txt>) 不是 MCP server 实现本体：它 spawn `CUA_REPL_NODE_REPL_PATH`，继承 stdio，设置 banner、trusted services、tool 描述 overrides。实际 schema 在 native node_repl。

[实测] 独立进程关闭 banner、trusted service 配置，发送 initialize→notifications/initialized→tools/list，正常关闭 stdin，child exit=0；完整 [schema](<raw/protocol/mcp-tools-list.json>)、[日志](<raw/protocol/probe-mcp-schema-run.log>)、[probe](<raw/protocol/probe_mcp_schema.py>)。生产 launcher 只覆盖描述/field descriptions，故 schema 形状与底层一致；本次没有用生产环境加载工具。

```json
{
  "js": {
    "type":"object", "additionalProperties":false,
    "properties":{
      "code":{"type":"string"},
      "title":{"type":"string","minLength":1,"maxLength":80},
      "timeout_ms":{"type":"integer","minimum":1}
    },
    "required":["code"]
  },
  "js_reset": {
    "type":"object", "additionalProperties":false, "properties":{}
  },
  "turn_ended": {
    "type":"object", "additionalProperties":false,
    "properties":{
      "hook_event_name":{"type":"string","minLength":1},
      "session_id":{"type":"string","minLength":1},
      "turn_id":{"type":"string","minLength":1}
    },
    "required":["hook_event_name","session_id","turn_id"]
  }
}
```

js 默认 timeout 30000ms（描述/运行实现默认，不是 schema default）；js_reset annotations readOnlyHint=true/destructiveHint=false/openWorldHint=false；turn_ended idempotentHint=true，`_meta.ui.visibility=[]`，说明同 session+turn 重复通知忽略。底层还返回 js_add_node_module_dir，但 [插件配置](<raw/protocol/plugin-mcp.json>) enabled_tools 仅三个目标工具。

### 7.2 REPL 的 cua 不是单纯 sky alias

[JS源码] [banner](<raw/protocol/repl-banner.js>) 导入 `@oai/cua/tinyskyAlt`；[globals](<raw/protocol/cua--lib--js--oai_js_cua--src--tinysky_alt--globals.js.readable.txt>) 创建全局 `cua`，并设 `initialize=getState`。

mac computer surface 启用时：

```text
cua.rewriteDocumentation(...)
cua.getState(...) / cua.initialize(...)
cua.computer = sky proxy（target/mac，snake_case 原始 API）
cua.listApps(...)
cua.getApp(appNameOrPathOrBundleID) -> app-bound object
```

app-bound object 的完整 mac 方法：`getAXState/getScreenshot/getAXStateAndScreenshot/paste/click/drag/pressKey/scroll/selectText/setValue/typeText/performSecondaryAction`。`getApp` 本身就调用 `get_app_state({app,disableDiff:true})`，因此不能作为无截图版本探测手段。

browser surface 启用还建立 `agent` 全局及合并 browser API；这不是 mac socket 协议本身。`nodeRepl` 常规执行上下文包含 cwd/homeDir/tmpDir/requestMeta 与 write/emitImage/emitAudio；privileged trusted runtime 才提供 nativePipe、launchServices、createElicitation 等桥接能力，不能假设任意用户 JS 都能直接使用。

### 7.3 生命周期链路与已知断点

[插件源码] [plugin manifest](<raw/protocol/plugin-manifest.json>)：

```text
Stop       -> mcp_tool(cua_repl.turn_ended,
                      {hook_event_name,session_id:${session_id},turn_id})
Interrupt  -> 同上
SubagentStop -> 同上，但 session_id:${agent_id}
```

[二进制内嵌 JS 证据] [node_repl strings:27606–27617](<raw/protocol/node-repl-strings.txt#L27606-L27617>)：收到 `{type:"turn_ended", event, ...}` 后建立 execState、activate context，执行 `privilegedRuntime.turnEndedHandlers.run(Object.freeze(message.event))`，finally clear context 并发送 `{type:"turn_ended_result",id}`。注册接口是 `nodeRepl.addTurnEndedHandler`，见 [runtime:24837–24868](<raw/protocol/node-repl-strings.txt#L24837-L24868>)。

**重要缺口：** 当前发布 sky/service/mac JS 没有 addTurnEndedHandler 注册，也未见客户端发 `ComputerUseIPCCodexTurnEndedRequest`。服务二进制确有该 request Codable 类型与 `handle(senderContext:)`，以及 `onCodexTurnEnded`。因此本次只证实“plugin→MCP→trusted lifecycle handlers”与“服务有 turn-ended handler”这两端；**没有证据把两端连成已实际发出的 socket 请求**。可能由别的 trusted/native 组件接续，或当前版本不在 sky JS 注册。未调用 turn_ended 做验证，以免终止生产 turn。

## 8. 可复现探测与风险评估

### 8.1 真实 socket probe

[probe 脚本](<raw/protocol/probe_socket.py>) 可从仓库根目录执行：

```bash
python3 re/raw/protocol/probe_socket.py
```

预先评估：只创建一条 AF_UNIX 连接，最多等待 250ms 被动 greeting；仅若对端保持连接才发送一次版本 ping；禁止启动服务、重试、list_apps、输入、截图、签名/身份伪装或授权绕过。可能产生普通服务连接/审计日志，可接受的最小副作用。3 秒读取上限、8 MiB frame cap，异常即停。

本次结果：connect 成功→空读取 EOF→停止。未发送任何 JSON 请求。故没有服务实际版本 reply、实际业务响应、帧抓包，也未拿到 JSON 错误 code；版本与帧结论由官方实现和离线序列化支持。

### 8.2 离线序列化 probe

[脚本](<raw/protocol/capture_serialization.mjs>) 用 EventEmitter FakePipe 模拟回复，只调用低层官方 client；不会调用 policy/approval、公有 sky wrapper 或 OS socket。包含的动作字符串与坐标**只是 JSON 样例，不发生动作**。

```bash
node re/raw/protocol/capture_serialization.mjs
```

[日志](<raw/protocol/offline-serialization-run.log>)、[帧集](<raw/protocol/offline-serialization-frames.json>)：14 帧 = 1 ping + 13 cases（11 方法中 click/scroll 各两种定位）。header/body 长度已断言。文件中绝对 deadline 是测试时钟产生，重跑会不同。

### 8.3 MCP schema probe

[脚本](<raw/protocol/probe_mcp_schema.py>) 仅启动独立 node_repl、禁用 banner/trusted services、请求 schema，然后 stdin EOF 正常退出。不触发真实 JS 求值、浏览器、computer service、turn-ended handler 或生产 PID 信号。

## 9. 开放问题 / 不应过度宣称

1. 认证 allowlist 的具体 team/signing IDs、祖先信任规则、连接拒绝内部函数路径，需定点反汇编或安全隔离测试补齐；当前只有明确认证失败实证。
2. nativePipe privileged host 的 OS 连接持有者与 audit identity 的完整实现未在本报告展开；不能使用 Python 的失败推断官方 signed runtime 也失败。
3. 服务错误数值与 JSON-RPC 标准错误的完整映射、服务的 frame/IO timeout 参数未全部独立反汇编。
4. 业务 response Codable 全字段（特别是 skyshot）未在线采样，表内只列 JS 实际读取部分。
5. `turn_ended` 到 ComputerUseIPCCodexTurnEndedRequest 的中间桥未确认；不能声称当前 sky JS 必然发送该消息。
6. 尚未得到独立 native Swift 客户端是否可授权连接的实测；没有尝试签名绕过、trusted executable 注入或宿主模拟。
7. protobuf descriptor 启发式未命中不等于物理不存在；目前无证据它属于此 socket 协议。
8. Windows screenshotId、Linux drag handles 与 mac 的不同已经区分，其他 target 未做完整逆向。

## 10. 原始材料索引

- [源码 manifest 与 SHA256](<raw/protocol/source-manifest.json>)；[全包文件清单](<raw/protocol/sky-file-inventory.txt>)。
- [传输 readable extract](<raw/protocol/sky-native-pipe.js.readable.txt>)；[client readable extract](<raw/protocol/sky-client.js.readable.txt>)。
- [服务 strings](<raw/protocol/server-strings.txt>)；[服务 nm](<raw/protocol/server-nm.txt>)；[筛选 demangle](<raw/protocol/server-protocol-symbols-demangled.txt>)。
- [descriptor 扫描](<raw/protocol/protobuf-scan.json>)；[node_repl 内嵌文本](<raw/protocol/node-repl-strings.txt>)。
- [socket probe](<raw/protocol/probe_socket.py>)、[在线运行记录](<raw/protocol/probe-socket-run.log>)、[同时刻服务认证失败日志](<raw/protocol/service-auth-log.txt#L30>)。
- [离线帧捕获](<raw/protocol/offline-serialization-frames.json>)、[MCP 完整 schemas](<raw/protocol/mcp-tools-list.json>)。
