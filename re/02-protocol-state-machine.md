# mac native socket 状态机与业务时序

证据详解见 [协议报告](<02-protocol.md>)；源码见 [native transport](<raw/protocol/sky-native-pipe.js.readable.txt>)。下图不是在线成功抓包：线上只达到“connect 后被拒绝”；其余依据官方 JS。

## 连接生命周期（[JS源码]）

```mermaid
stateDiagram-v2
    [*] --> GetTransport
    GetTransport --> Ready: 同 apiVersion cached 且未 closed
    GetTransport --> Connect250: 缓存不存在或已 closed
    Connect250 --> Ping: OS connect 成功
    Ping --> Ready: serverApiVersion 精确相等
    Ping --> Fatal: mismatch / error -10013
    Connect250 --> Retry: 可恢复连接错误
    Ping --> Retry: 其他握手错误
    Retry --> Connect250: 预算未到，等待 100ms
    Retry --> EnsureService: 初始 250ms 预算耗尽
    EnsureService --> Connect5000: host ensureService 或 LaunchServices 成功
    EnsureService --> Fatal: 启动请求失败
    Connect5000 --> Ping2: connect 成功
    Connect5000 --> Fatal: 5000ms 预算耗尽
    Ping2 --> Ready: 版本相等
    Ping2 --> Connect5000: 可恢复错误且有预算
    Ping2 --> Fatal: mismatch / -10013
    Ready --> Closed: timeout / error / EOF / malformed response
    Closed --> GetTransport: 下一次调用（不重放旧动作）
    Fatal --> [*]
```

请求内部由 promise 链串行；队列等待不计入该 request 的 timeout/deadline；实际发送时计算绝对 deadline。pending map 按递增 number id 匹配。任一超时关闭整条连接并 reject 所有 pending；收到单个合法 JSON error 则只 reject 对应请求。

## 正常 public sky click（[JS源码]，未在线执行）

```mermaid
sequenceDiagram
    participant JS as 用户 JS / cua app binding
    participant Sky as trusted sky/service
    participant Pipe as MacNativePipeTransport
    participant Svc as SkyComputerUseService
    participant Approval as nodeRepl elicitation
    JS->>Sky: rpc sky {type:execute,method:click,args:[...]}
    Sky->>Pipe: getAppPolicy(app)
    opt 首次 transport
        Pipe->>Svc: connect socket（peer auth 在应用帧前）
        Pipe->>Svc: LE length + ping(clientApiVersion)
        Svc-->>Pipe: result.serverApiVersion
    end
    Pipe->>Svc: request(ComputerUseIPCAppPolicyRequest,{app})
    Svc-->>Pipe: policy decision + target
    Sky->>Approval: createElicitation(app approval)
    Approval-->>Sky: accept / decline / cancel
    alt allowed 且 accept
        Sky->>Pipe: performAction(target.appPath, action.click)
        Pipe->>Svc: request(ComputerUseIPCAppPerformActionRequest,{app,action})
        Svc-->>Pipe: result 或 error
        Sky-->>JS: undefined 或 throw
    else policy/approval 拒绝
        Sky-->>JS: throw（没有动作请求）
    end
```

## 本次真实连接（[实测]）

```text
Python PID 57447          SkyComputerUseService PID 14867
       connect()  -------------------->
       CONNECT_OK <--------------------
                                       08:22:05.018 日志：
                                       Sender process is not authenticated
       recv() = b"" <------------------ EOF
       STOP（未 write ping）
```

见 [probe 日志](<raw/protocol/probe-socket-run.log>) 与 [认证日志:30](<raw/protocol/service-auth-log.txt#L30>)。OS connect 成功仅说明监听 socket 可达，不说明 peer 已获应用授权。
