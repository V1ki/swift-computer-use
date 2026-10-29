# Codex Computer Use：Bundle、Mach-O、签名及启动机制取证

## 0. 范围、方法与结论等级

分析对象是 [Codex Computer Use.app](</Users/v1ki/.codex/computer-use/Codex Computer Use.app>)（以下简称服务包）；宿主是 [ChatGPT.app](</Applications/ChatGPT.app>)，但其 bundle identifier 实为 `com.openai.codex`。本报告对**服务包内部全部六个 Mach-O**进行完整静态采集，额外分析宿主的主 launcher；**没有宣称遍历分析宿主 Electron 所有 framework/native module**。

- 原始样本只读；没有执行目标可执行文件、安装/卸载插件、修改 TCC/authorizationdb/launchd、终止 PID 14867 或读取旧研究。
- 取证环境：macOS 27.2 / build 26B123、arm64、Xcode 27.1 / 27A9275，见[系统版本](<raw/bundle/environment.txt>)与[Xcode](<raw/bundle/xcode.txt>)。样本构建 SDK 与当前取证 SDK 不同。
- “确定”= 文件内容、签名、Mach-O 导入/导出、系统只读查询直接证明；“支持”= 类型/符号/字符串支持此设计；“未证实”= 未恢复完整控制流或实际运行行为。字符串不是网络访问记录，导入不是已执行调用，构建依赖不是动态链接依赖。
- [复现脚本](<raw/bundle/run.sh>)只向固定 raw 输出目录写入；每项命令输出记录命令、退出状态与 stderr。补充静态解码与只读系统查询也在脚本中。PID/UID、版本及地址限定为本次样本，其他机器需调整。

### 核心发现

1. 服务包是 **Swift/Objective-C 原生、非 sandbox、hardened runtime 的辅助应用**，不是 Electron 服务。宿主 launcher 很小，其 Electron 身份不能外推到服务二进制。
2. Bundle 含主服务、Guardian、CLI、授权插件安装器、SecurityAgent 授权插件、提权安装工具共六个 arm64 Mach-O；共享业务模块大量静态链接到主服务与 Guardian。
3. 主包 167 文件、64 子目录、77,600,657 字节；逐文件 SHA256 与宿主所带同路径副本**全部相同**。这证明样本副本一致，不单独证明复制动作由哪个进程执行。
4. 主服务至少保留 JSON-RPC Unix socket 与 XPC 两套传输实现；Guardian 有 Mach bootstrap rendezvous、NSXPC endpoint 与专门锁屏协议。
5. 该机授权数据库已经配置锁屏授权插件分支；不仅是包内留存未使用的安装器。服务 PID 14867 直接父进程为宿主 PID 1508，launchd 将它列为 unmanaged，而非查到固定 label 的 LaunchAgent。
6. 签名深校验成功；Gatekeeper 接受为 `Notarized Developer ID`；**服务包本身没有 stapled ticket**。宿主签名则显示 stapled ticket。两者不可混淆。

## 1. 完整目录树、元数据与资源角色

完整逐目录、逐文件大小和角色见[完整树](<raw/bundle/tree.txt>)；每个文件 SHA256 见[哈希清单](<raw/bundle/hashes.txt>)；主包与宿主嵌入副本比较见[逐文件比较](<raw/bundle/host-copy-comparison.txt>)。以下为结构摘要，不替代完整树：

```text
Codex Computer Use.app/Contents/
  Info.plist, PkgInfo, embedded.provisionprofile, _CodeSignature/CodeResources
  MacOS/SkyComputerUseService
  Resources/
    Assets.car, CUAAppIcon.icns, BUILD.bazel
    Package_Appshot.bundle/             # 截图提示音
    Package_ComputerUse.bundle/         # app instructions、Lens 动画、Skysight 指令、资产
    Package_SlimCore.bundle/            # 通用提示箭头、软件光标资产
    SwiftProtobuf_SwiftProtobuf.bundle/ # SwiftProtobuf 隐私清单
  SharedSupport/
    CUALockScreenGuardian.app/          # 与主服务共享大量业务实现、锁屏守护
    SkyComputerUseClient.app/          # 客户端/CLI；独立 profile、父进程要求配置
    Codex Computer Use Installer.app/
      Contents/MacOS/Codex Computer Use Installer
      Contents/Resources/
        CodexComputerUseAuthorizationPlugin.bundle/Contents/MacOS/...
        CodexComputerUseAuthorizationPluginInstallerTool
```

目录扫描没有发现 `Contents/XPCServices`、`Contents/Library/LoginItems`、内嵌 LaunchAgent/Daemon plist 或内嵌动态 framework。**存在 XPC 代码不等于存在独立 .xpc bundle**。

### 1.1 Info.plist 全量展开与重要键

[plist 索引](<raw/bundle/plist-index.txt>)列出所有 14 个目标 Info.plist、3 个 SwiftProtobuf 隐私清单以及宿主 Info.plist 的解码路径。

|对象|Bundle identifier|版本/最低系统|角色/特别键|
|---|---|---|---|
|[主服务](<raw/bundle/plists/00-Codex Computer Use.app-Info.plist.txt>)|`com.openai.sky.CUAService`|26.1013.1001501 / 14.4|DisplayName=`ChatGPT Computer Use`；Executable=`SkyComputerUseService`；`LSUIElement=true`|
|[Guardian](<raw/bundle/plists/06-CUALockScreenGuardian.app-Info.plist.txt>)|`com.openai.sky.CUAService.guardian`|同主服务 / 14.4|`LSUIElement=true`|
|[Installer](<raw/bundle/plists/12-Codex Computer Use Installer.app-Info.plist.txt>)|`com.openai.sky.CUAService.AuthorizationPluginInstaller`|同主服务 / 14.4|独立安装应用|
|[授权插件](<raw/bundle/plists/13-CodexComputerUseAuthorizationPlugin.bundle-Info.plist.txt>)|`com.openai.sky.CUAService.AuthorizationPlugin`|同主服务 / 14.4|BNDL，SecurityAgent 动态加载|
|[CLI](<raw/bundle/plists/14-SkyComputerUseClient.app-Info.plist.txt>)|`com.openai.sky.CUAService.cli`|同主服务 / 14.4|`LSUIElement=true`，可执行名 SkyComputerUseClient|
|[宿主](<raw/bundle/plists/17-ChatGPT.app-Info.plist.txt>)|`com.openai.codex`|26.1013.31256|不是历史 `com.openai.chat` 身份|

主服务 build=`1001501`、SDK=`26.1`、DTXcode=`2611`、DTXcodeBuild=`17B100`、BuildMachineOSBuild=`25D2128`。Package_ComputerUse 等 resource bundle 最低系统为 14.0，不能据此把可执行服务最低系统降为 14.0。

主服务 TCC usage 文案（原文）:

- AppleEvents：`By default, ChatGPT sends messages only after you approve the message and its recipients.`
- Calendar：`ChatGPT uses Calendar to read and manage your events.`
- Contacts：`ChatGPT uses Contacts to show names and find phone numbers or email addresses for people you ask to message.`

SwiftProtobuf [隐私清单](<raw/bundle/plists/05-Contents-PrivacyInfo.xcprivacy.txt>)为 tracking=false、tracking domains/collected data/accessed API types 空数组；这是**库的清单，不是整个服务无数据收集的证明**。

### 1.2 Provisioning profiles 与父进程要求文件

两份 profile 已用 `security cms -D` 全量解码，包括证书 blob、UUID、时间、平台及 allowed entitlements：

|Profile|UUID|创建 / 到期 UTC|授权范围摘要|
|---|---|---|---|
|[主服务](<raw/bundle/profiles/01-decoded.txt>)|`0377ed62-fd19-473e-a0fe-32d309c1ff8f`|2026-05-12 22:29:26 / 2044-05-07 22:29:26|Team 2DC432GLL2；group.com.openai.sky.CUAService；2DC432GLL2.*|
|[CLI](<raw/bundle/profiles/00-decoded.txt>)|`eb4f52dd-1c79-495b-9682-e2e5732f4c07`|2026-05-12 22:29:35 / 2044-05-07 22:29:35|还允许 group.com.openai.sky.Service；ProvisionsAllDevices=true|

Profile 的允许范围和可执行代码实际 entitlements 是两套不同证据；运行权限以签名里的实际 entitlements 为准。

[Guardian 父要求](<raw/bundle/parent-CUALockScreenGuardian_Parent.txt>)和[CLI 父要求](<raw/bundle/parent-SkyComputerUseClient_Parent.txt>)虽然扩展名是 `.coderequirement`，内容却是 XML plist，仅含 `team-identifier=2DC432GLL2`。初次误用 `csreq` 返回语法错误，已改用 `plutil` 正确解码；**不能把这些文件声称为 Apple 编译后的 requirement blob 或“只允许某一个 bundle ID”**。

## 2. Mach-O 全覆盖

### 2.1 基本事实

全部六个目标 Mach-O 均为**单架构 arm64**，不是 Universal/x86_64。六者 `LC_BUILD_VERSION` 均为 macOS、minos 14.4、sdk 26.1、linker 1230.1。宿主 launcher minos 13.0、sdk 26.0，tool 4 version 24.0。证据路径见本节末的逐二进制索引。

|二进制|字节|类型|load commands / sizeofcmds|入口|
|---|---:|---|---:|---|
|主服务|24,934,560|MH_EXECUTE|90 / 10048|LC_MAIN entryoff=17729984；VA=0x1010e89c0；符号名被 redacted|
|Guardian|24,564,800|MH_EXECUTE|90 / 10128|`_main` 0x10000299c；entryoff=10652|
|Installer|90,480|MH_EXECUTE|31 / 3240|`_main` 0x1000013e4；entryoff=5092|
|AuthorizationPlugin|67,872|MH_BUNDLE|19 / 2712|无 LC_MAIN；`_AuthorizationPluginCreate` 0xaf8|
|InstallerTool|109,776|MH_EXECUTE|30 / 3272|`_main` 0x1000024c8；entryoff=9416|
|CLI|15,502,928|MH_EXECUTE|70 / 8328|`_main` 0x100002180；entryoff=8576|
|宿主 launcher（额外）|71,008|MH_EXECUTE|15 / 1800|`_main` 0x100000748；entryoff=1864|

可执行均有 PIE；插件 BUNDLE 无 PIE 标记。主服务与 Guardian 有 WEAK_DEFINES / BINDS_TO_WEAK；主服务、Guardian、Installer、Tool、CLI 均有 `NLIST_OUTOFSYNC_WITH_DYLDINFO`，因此同时保留 nm 与 dyld_info 输出，不能仅靠其中一种枚举推断运行时全部绑定。

主服务、Guardian、CLI 的 rpath 相同：`/usr/lib/swift`、`@executable_path/Frameworks`、`@executable_path/../Frameworks`；Installer 为前述第一、第三项；Tool 仅 `/usr/lib/swift`；插件与宿主 launcher 无 rpath。**保留 framework rpath 不等于包里真有 Frameworks 目录。**

主服务 `LC_CODE_SIGNATURE dataoff=24723616 datasize=210944`；UUID、全部 segment/section、所有 load command、其余签名偏移均逐个保存在原始输出，没有用抽样替代。

### 2.2 动态依赖与静态模块

[主服务 otool -L](<raw/bundle/macho/00-SkyComputerUseService/libraries.txt>)显示 Foundation、AppKit、SwiftUI、ApplicationServices、CoreGraphics、ScreenCaptureKit、QuartzCore、AVFoundation、AVFAudio、CoreMedia、CoreVideo、VideoToolbox、Security、ScriptingBridge、Contacts、EventKit、CoreLocation、WebKit、Network、OSLog、OpenDirectory、IOKit、ImageIO、MapKit、Intents、Carbon 等系统 framework 和 Swift runtime/overlay。`dyld_info -dependents` 另保留 weak/reexport 等加载属性。

业务模块 `ComputerUse`、`ComputerUseClient`、`ComputerUseCore`、`AccessibilitySupport`、`SystemSoftware`、`Appshot`、`Fog`、`SlimCore` 等有真实定义符号，但不是独立加载的同名 dylib：它们已链接到目标镜像。`OAIProtobuf`、`SwiftProtobuf`、MCP、SQLite、Statsig 等同理。

**边界**：Sparkle 在元数据/构建规则中出现，但本次主服务 load commands 没有 Sparkle dylib，符号/字符串检索未找到可确认的 updater 实现；不能只因 SUFeedURL 就断言本镜像启动了 Sparkle updater。SkyLight 也不是这里明确列出的动态依赖，但有 `captureScreenshotWithSkyLight` 符号与动态解析层，见第 7 节。

## 3. 签名、entitlements、resource seal 与公证

所有目标 Mach-O 的签名均显示 `Developer ID Application: OpenAI OpCo, LLC (2DC432GLL2)`，链为 Developer ID Certification Authority → Apple Root CA；CodeDirectory `flags=0x10000(runtime)`，runtime 26.1。**Hardened Runtime 与 App Sandbox 不等价。**

|对象|实际 entitlements 摘要|resource seal|
|---|---|---|
|[主服务](<raw/bundle/signatures/00-Codex Computer Use.app.txt>)|application-id=2DC432GLL2.com.openai.sky.CUAService；team；application-groups=[2DC432GLL2.com.openai.sky.CUAService]；automation.apple-events=true；personal-information.addressbook/calendars=true；keychain-access-groups=[2DC432GLL2.*]|v2，163 files；时间 Oct 14 2026 03:25:22（工具本地时间）|
|[Guardian](<raw/bundle/signatures/05-CUALockScreenGuardian.app.txt>)|未输出 entitlement XML|69 files|
|[Installer](<raw/bundle/signatures/10-Codex Computer Use Installer.app.txt>)|空 dict|6 files|
|[插件](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/signatures.txt>)|未输出 entitlement XML|0 resource files；代码本体仍签名|
|[Tool](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/signatures.txt>)|仅 application-id=2DC432GLL2.com.openai.sky.app.CodexComputerUseAuthorizationPluginInstallerTool|独立 Mach-O，无 resource seal；identifier 带 UUID 后缀|
|[CLI](<raw/bundle/signatures/12-SkyComputerUseClient.app.txt>)|application-id/team/app group/keychain 与主服务对应；没有 AppleEvents/Contacts/Calendar 项|6 files|
|[宿主](<raw/bundle/signatures/14-ChatGPT.app.txt>)|app-sandbox=false；allow-jit/allow-unsigned-executable-memory=true；audio-input/camera；AppleEvents/Calendar；共享 CUAService group 与 keychain|3626 files；ticket=stapled|

主服务没有 `com.apple.security.app-sandbox=true`，也没有宿主的 JIT/unsigned-memory 例外。资源 bundle 独立 codesign 查询返回 `code object is not signed at all`，虽然各自有 CodeResources；**资源 seal 文件不等于独立可执行代码签名**。主包[完整 deep strict 校验](<raw/bundle/signature-verification.txt>)仍成功。

[resource seal 结构统计](<raw/bundle/code-resources-summary.txt>)包含每个 CodeResources 大小和 files/files2/rules/rules2 数；主包 legacy files=69、files2=163，Guardian 69/69；CLI 5/6，不要把 files 与 files2 相加当文件总量。实际 designated requirement 由每个 signature 的 companion `-requirement` 输出保存。

[Gatekeeper](<raw/bundle/gatekeeper-assessment.txt>)返回 accepted，source=Notarized Developer ID；[stapler](<raw/bundle/notarization-staple.txt>)返回 65、没有 stapled ticket。因此结论是“系统认可已公证签名，但当前服务包未附票”，不是“未公证”。

## 4. 全符号统计、Swift 类型与 Objective-C

统计来源：[nm 与类型统计](<raw/bundle/symbol-statistics.txt>)及[基础二进制统计](<raw/bundle/macho-summary.txt>)。nm 总数不含命令 framing；undefined 按符号项计数。dyld imports 数是**绑定地址记录条数，不是去重函数数**。

|二进制|nm 全部|external defined|undefined|redacted 项|Swift nominal descriptors / protocol descriptors|运行时 mangled 类型名|定义 ObjC classes|
|---|---:|---:|---:|---:|---:|---:|---:|
|主服务|170704|68710|1156|98242|2195 / 186|352|243|
|Guardian|169303|68711|1126|97041|2195 / 186|331|221|
|Installer|105|2|58|43|0 / 0|1|1|
|Plugin|35|3|32|0|0 / 0|0|1|
|Tool|151|2|63|86|0 / 0|0|0|
|CLI|118765|52497|536|64257|1492 / 93|163|131|
|宿主 launcher|42|1|40|0|0 / 0|0|0|

这里“0 nominal descriptor”不代表不是 Swift：Installer/Tool 仍有 Swift runtime、mangled 元数据/字符串；已保留 runtime name 与 ObjC metadata 双路径。许多主服务自身 Swift 类型不在公开 nominal descriptor 列表中，但运行时 `_TtC…` 名称仍可恢复。**2195 不是全部源代码类型数量，也不是 unique classes 数。**

### 4.1 按模块归并

主服务与 Guardian 的 public nominal descriptor 数一致；核心模块如下，完整 50 余模块列表见[主服务分组清单](<raw/bundle/macho/00-SkyComputerUseService/swift-types-all-grouped.txt>)。每个二进制亦生成 runtime class/protocol 名按模块分组的文件，补上被 redacted 的私有主模块。

|模块|nominal types|架构含义与代表类型|
|---|---:|---|
|ComputerUse|128|ComputerUseIPCSocket、ComputerUseIPCJSONRPCSocketConnection、ComputerUseIPCXPCSession、CaptureStream、ComputerUseCursor、ComputerUseAppInstance、SystemLockScreenAXInteractor|
|ComputerUseClient|145|请求/响应模型、ComputerUseIPCXPCTransport、JSONRPCLineBuffer、AppApprovalStore、MessagesSendApprovalStore、ComputerUseMCPTurnMetricsTracker|
|ComputerUseCore|38|AccessibilityNode/role/rendering、共享 UI 树表示|
|AccessibilitySupport|75|ApplicationUIElement、WindowUIElement、SyntheticAppFocusEnforcer、AXNotificationObserver、SystemFocusedUIElementObserver|
|SystemSoftware|22|CGEventAPI、CGWindow、系统包装|
|SlimCore|81|ScreenshotImplementation、系统权限/设置界面、图文/应用辅助|
|Fog / Appshot|9 / 1|背景视觉层、壁纸/截图提示；runtime 清单额外发现多个私有类型|
|CalendarCore / ContactsCore / MessagesCore|28 / 13 / 54|领域适配器，不是仅有鼠标键盘|
|MCP|186|方法、Transport、请求/通知、JSON schema/OAuth 支撑|
|OAIProtobuf / SwiftProtobuf|562 / 156|大量 analytics generated types；不可把所有 Codex analytics enum 当成本服务功能|
|Statsig / Logging / SwiftLogging|38 / 18 / 10|特性开关、遥测、日志|
|SQLite / SQLiteSchema / DatabaseSupport|68 / 16 / 8|数据库访问与 schema 抽象|
|SoftLink|7|ResolvedImage、SymbolRequest、SipHashState、Mach-O linkedit 解析|

主服务 runtime 名还恢复 `Codex_Computer_Use.CUAServiceApplicationDelegate`、`CUALockScreenGuardianClient`、`CUAServicePermissionState`、`CUAServiceRemoteHostedPIPController`、`RecordAndReplayOverlayController`、`ChromeExtensionInstaller`。注意构建规则 Swift module 标为 CUAService，而实际 runtime 名使用 `Codex_Computer_Use`；应报告观察值，不能强行统一命名。

### 4.2 协议与 ObjC 入口

[全部 Swift protocols](<raw/bundle/macho/00-SkyComputerUseService/swift-protocols-all.txt>)包括：

- `ComputerUse.ExecutableComputerUseIPCRequest`、`ExecutableComputerUseIPCRequestWithFileHandles`；`ComputerUseClient.ComputerUseIPCRequest`、`ComputerUseIPCRequestWithFileHandles`。
- `ComputerUse.LockScreenController`、`LockScreenGuardian`、`LockScreenLoginAuthorizationApprover`、`LockScreenMonitor`、`LockScreenOverlayPresenter`、`LockScreenPhysicalInputMonitor`。
- `AccessibilitySupport.AXUIElementProtocol`、`UIElementProtocol`、`VirtualCursor`、`WindowUIElementProtocol`；`ComputerUseCore.AccessibilityNode`、`MutableAccessibilityNode`、`UIElementTraversable`。
- MCP.Transport / Method / Notification；Logging.AnalyticsEventTransport 等。

[定义 ObjC classes](<raw/bundle/macho/00-SkyComputerUseService/objc-classes-defined.txt>)里除桥接 Swift 类外还有 `CUAServiceApplication`、`SAIMachBootstrapRendezvous`、`SAIRemoteLayerContext`、`SAIRunningProcess`、`SAIRunningProcessFilter`、`SAIVirtualKeyPress`、`SAIWebArchive`。完整 `otool -ov` 保存类、方法、selector、protocol 元数据；Guardian 专有 `SAILockScreenGuardianXPCProtocol` / `SAILockScreenGuardianClientXPCProtocol` 是 ObjC/XPC 协议，不应只在 Swift protocol descriptor 列表找。

主服务 `_main` 的人类可读名称已被移除；LC_MAIN 与 `<redacted LC_MAIN>` 对齐足以定位入口，不需要杜撰原始入口函数名。插件公开三个符号为 AuthorizationPluginCreate 与 mechanism class/metaclass，支持标准 Authorization Plugin 接口。

## 5. 字符串分类与解释

所有二进制原始 strings、完整合并表和分类表均落盘；[合并字符串](<raw/bundle/all-strings.txt>)每行带二进制来源。分类基于脚本明确正则，因此存在交叉和噪声；JSON-key candidate 只是词法候选，**不能当成恢复的完整 wire schema**。

### 5.1 URL/域名与更新

[URL/域名类](<raw/bundle/macho/00-SkyComputerUseService/strings-urls-domains.txt>)明确含：

- `https://chat.openai.com/ces/v1/telemetry/intake`、`https://chatgpt.com/ces/v1/rgstr`：遥测/注册相关字符串。
- `https://api.openai.com/auth`、`https://api.openai.com/profile`、`https://chatgpt.com/backend-api`。
- `https://ab.chatgpt.com`；Statsig 默认相关 `featureassets.org/v1/initialize`、`prodregistryv2.org/v1/rgstr`、`statsigapi.net/v1/sdk_exception`；`cloudflare-dns.com/dns-query`。
- Chrome Web Store Codex extension 链接；`http://127.0.0.1:` / `http://localhost:` 前缀。

这些都只是内嵌常量；未进行流量监听，不能断言都实际请求。

主服务 Info.plist：`SUFeedURL=https://oaisidekickupdates.blob.core.windows.net/mac/cua/alpha/appcast.xml`；`SUPublicEDKey=5Yw9jMXMH6O3mJZmpFuQT6ECfC3ZKBfVjWUVMNrElRo=`；automatic checks、automatic updates、verify-before-extraction 为 true。这是更新配置存在的确定证据；本次未请求 feed，也未证明 updater 在运行。

### 5.2 IPC、版本与启动路径

[IPC/路径分类](<raw/bundle/macho/00-SkyComputerUseService/strings-ipc-launch-paths.txt>)、[客户端 IPC 分类](<raw/bundle/macho/05-SkyComputerUseClient/strings-ipc-launch-paths.txt>)和[版本分类](<raw/bundle/macho/00-SkyComputerUseService/strings-updates-version.txt>)包含：

- `computeruse.sock`；`com.openai.sky.computer-use-json-rpc-socket`；`com.openai.sky.computer-use-json-rpc-socket-readiness`。
- `/tmp/com.openai.sky.CUAService/LockScreenLoginAuthorization.sock` 是**锁屏授权专用 socket**，不能与普通 computeruse.sock 混为一个协议。
- `ComputerUseIPCJSONRPCSocketConnection`、`ComputerUseIPCXPCTransport`、`SAIXPCEndpointTransport`、`SAIMachBootstrapRendezvous`。
- `Could not get XPC bootstrap mach port from Apple event`、`Computer Use bootstrap response has no XPC endpoint.`；Guardian Mach rendezvous 创建/注册失败文本。
- `protocolVersion`、`ipcProtocolVersion`、`supportedProtocolVersions`、`incompatibleClientVersion`、`MCP-Protocol-Version`；存在让用户重新启动 ChatGPT 的版本不匹配错误。IPC version 和 MCP protocol version 应分别处理；不能仅凭这些字段声称已经恢复具体整数版本/协商算法。

### 5.3 日志、错误、权限、JSON/protobuf

- [日志分类](<raw/bundle/macho/00-SkyComputerUseService/strings-logging.txt>)：`com.openai.sky.CUAService`、`com.openai.codex.computer-use.status-item-state-changed`、`Logging.LoggerSubsystem`、`subsystem BEGINSWITH %@`、`logging/setLevel`。一些 com.openai.* 是应用白名单/识别项，不应全称为 os_log subsystem。
- [错误分类](<raw/bundle/macho/00-SkyComputerUseService/strings-errors.txt>)保留完整失败信息，包括权限、socket 身份/owner/mode 验证、IPC 版本、捕获、锁屏以及嵌入依赖库错误。SQLITE_* 等库词条不等于曾发生的运行错误。
- [权限分类](<raw/bundle/macho/00-SkyComputerUseService/strings-permissions.txt>)：AccessibilityPermission、ScreenRecordingPermission、FullDiskAccessPermission、AppleEventsPermission、Calendar/Reminders/Contacts/LocationPermission、PermissionRequester、PermissionCatalog。类型存在说明有通用权限框架，不证明全在主 UI 显示、全已授权或应用可绕过 TCC。
- [protobuf/JSON 分类](<raw/bundle/macho/00-SkyComputerUseService/strings-protobuf-json.txt>)包含 SwiftProtobuf descriptor、`protobuf_analytics_events.v1.*`、JSONRPC、CodingKeys；[key candidates](<raw/bundle/macho/00-SkyComputerUseService/strings-json-key-candidates.txt>)是后续 schema 还原的索引，不是可信字段白名单。

## 6. 启动、注册、IPC 身份与授权插件

### 6.1 运行时只读快照

[ps 父子关系](<raw/bundle/registration-process-parent.txt>)确定服务 PID 14867 的 PPID=1508；1508 是宿主进程，PPID=1。服务进程可执行路径落在用户 `.codex/computer-use` 副本。[launchctl GUI 域](<raw/bundle/launchctl-gui.txt#L2037>)含 `com.apple.xpc.launchd.unmanaged.SkyComputerUseS.14867`。

固定 label `gui/501/com.openai.sky.CUAService`、`system/com.openai.sky.CUAService`、[`.agent`](<raw/bundle/launchctl-agent.txt>) 查询均 113（找不到）；[launch plist 扫描](<raw/bundle/launch-plists.txt>)在用户 LaunchAgents、系统 LaunchAgents/LaunchDaemons 未发现匹配。构建规则确有 `SERVICE_AGENT_LABEL=com.openai.sky.CUAService.agent`，但“存在常量”不能推翻当前运行快照。

**最小可证结论**：当前服务由宿主进程直接作为父进程持有，launchd 视作 unmanaged；尚未发现传统固定 LaunchAgent 注册。没有据此断言所有启动情形永不使用 launchd 或 NSWorkspace。

### 6.2 授权插件链：包内能力 + 本机已注册事实

[插件 strings](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings.txt>)清楚显示 AuthorizationPluginCreate、MechanismCreate/Invoke/Deactivate/Destroy、Allow/Deny、socket 错误与 peer code-signing identity 检查。期望 identifier=`com.openai.sky.CUAService`、team=`2DC432GLL2`，从 socket peer audit token 检查身份；**不是只按文件路径信任任何同名进程**。

[Installer strings](<raw/bundle/macho/02-Codex Computer Use Installer/strings.txt>)声明 install/uninstall/status，使用 `system.privilege.admin`；[Tool strings](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings.txt>)含 AuthorizationRightGet/Set、root:wheel、权限硬化、备份 manifest、屏幕解锁规则和安装目的地。它表明此功能需要特权系统配置，不能照普通 helper app 处理。本次没有执行这些动作用途的目标程序。

本机[插件目录存在](<raw/bundle/installed-plugin-list.txt>)；更重要的是两个只读授权数据库查询成功：

- [system.login.screensaver](<raw/bundle/authorizationdb-screensaver.txt>)：class=rule，k-of-n=1，rule=[`com.openai.sky.CUAService.AuthorizationPlugin.remote`, `use-login-window-ui`]。
- [remote rule](<raw/bundle/authorizationdb-remote.txt>)：class=evaluate-mechanisms，mechanisms=[`CodexComputerUseAuthorizationPlugin:allow`]，tries=1；comment 明言询问 active Computer Use login authorization pending。

这是已经安装并进入系统解锁授权路径的直接证据。仍未实测是否某次解锁得到 Allow，也未恢复失败/无响应时所有控制流，因此不能把字符串中的 Allow 或规则名当成无条件绕过锁屏结论。

## 7. 等价实现所需系统 API 与私有接口边界

下表把“明确导入”与“存在包装/动态解析证据”分开，避免凭 API 名猜实现。

|能力|强证据|等价实现 API 家族与限制|
|---|---|---|
|AX 树/动作|[undefined 11–39](<raw/bundle/macho/00-SkyComputerUseService/nm-undefined.txt#L11-L39>)：AXUIElementCopyAttributeValue(s)、CopyMultipleAttributeValues、CreateApplication/SystemWide、PerformAction、SetAttributeValue、AXObserver*|ApplicationServices Accessibility API；需用户授权；AXTextMarker* 属更谨慎的 SPI 边界|
|键盘/鼠标|[demangled CGEventAPI](<raw/bundle/macho/00-SkyComputerUseService/nm-demangled.txt#L142333-L142356>)：createKeyboardEvent、createScrollWheelEvent、post/postToPid、tapCreate(ForPid)、UnicodeString 等|CoreGraphics CGEvent、CFMachPort event tap、权限与进程定向；多数通过包装/解析而非普通 undefined 直连。直接导入仅见如 CGEventGetFlags，不能把整个包装表说成导入表|
|截图/录屏|ScreenCaptureKit 链接、SCStream/SCShareableContent 等类、CGPreflightScreenCaptureAccess/CGRequestScreenCaptureAccess、CGWindowList* 导入|ScreenCaptureKit、CoreGraphics window enumeration、ImageIO 编码、CoreMedia/CoreVideo/VideoToolbox；须屏幕录制授权|
|私有窗口/截屏能力|`_CGSMainConnectionID` 明确来自 CoreGraphics；`SlimCore.ScreenshotImplementation.captureScreenshotWithSkyLight` 定义；SoftLink.SipHashState/SymbolRequest 等|存在私有/SPI、动态解析路径。未将哈希常量全部逆解，不声称所有 CGS/SLS 私有函数名称已恢复|
|应用/窗口/overlay|NSApplication、NSWorkspace、NSRunningApplication、NSWindow/NSPanel，CALayer、SwiftUI/Fog/SAIRemoteLayerContext|AppKit、QuartzCore、SwiftUI；焦点保持、坐标转换、遮罩/虚拟光标与 PiP 不只是事件注入|
|IPC/对端校验|NSXPC、Mach rendezvous、socket，SecCodeCopyGuestWithAttributes/SecCodeCopySigningInformation、audit token|NSXPCConnection/ListenerEndpoint、Mach port、AF_UNIX；要验证 UID、目录 owner/mode、对端签名/团队和协议版本|
|AppleEvents 与领域集成|AEDeterminePermissionToAutomateTarget、ScriptingBridge、Contacts/EventKit 等链接与权限类型|AppleEvents/ScriptingBridge、CNContactStore、EKEventStore，独立 TCC 与最小范围审批|
|锁屏守护/授权|Guardian protocols、OpenDirectory、AuthorizationPluginCreate、AuthorizationRightGet/Set|系统插件属于特权安装和 OS 版本敏感路径；基础桌面自动化不必实现此扩展|
|持久化/网络/遥测|SQLite、SwiftProtobuf、MCP、Network、Logging/Statsig 类型与 URL 常量|这些是进程内依赖/协议工具，不自动说明服务承担远端模型推理|

截取了[CGEvent 包装器反汇编](<raw/bundle/disassembly-cgevent.txt>)和[SkyLight 截图附近反汇编](<raw/bundle/disassembly-skylight.txt>)供地址核验。由于 nlist 与 dyld 信息不同步，llvm-objdump 在相邻范围给出的符号标签可能错位；应以 nm 定义地址/指令地址为锚，**不能把错误最近邻标签当成真实函数名或完整调用图**。

最小可替代系统应分为：权限与审批、AX/窗口抽象、截图与编码、输入与焦点、IPC 与签名鉴权、CLI/MCP 适配、UI 状态/恢复。锁屏 Guardian + Authorization Plugin 是额外子系统，具有管理员安装、安全审核和版本兼容要求，不应未经用户同意自动部署。

## 8. 构建规则与资源内容

包内保存了[主服务 BUILD.bazel](<raw/bundle/resources/00-BUILD.bazel.txt>)及[CLI BUILD.bazel](<raw/bundle/resources/20-BUILD.bazel.txt>)，是高价值构建证据但不等于完整源代码：

- 主服务：ObjC library `CUAServiceLauncher`、源文件 `main.m`；Swift library module `CUAService`，swift_version=5；minimum_os_version=14.4；可执行名 SkyComputerUseService；常量定义 bundle ID、team app group、service-agent label。
- 依赖 ComputerUse、ComputerUseClient、CodexAnalytics、Fog、GraphicsSupport、Logging、SlimCore、OAIProtobuf、OAIStatsig、Sparkle、SwiftProtobuf 等。Swift version 5 是语言模式，不应称为编译器具体版本。
- CLI 源名 `SkyComputerUseClient.swift`，依赖 AppConstants 与 ComputerUseClient，最低系统 14.4。

[资产名全集](<raw/bundle/asset-names.txt>)来自 7 个 Assets.car 的 `assetutil --info`，完整 metadata 保存在 assets 子目录。主资产包括 Accessibility、Screenshot、AppshotLogo、SkysightLogo、ChronicleStatusPaused/Running、menubar-cursor、CUAAppIcon 各图层；ComputerUse 资源为 SoftwareCursor；SlimCore 为 HintArrow/SoftwareCursor。不能由图标名推导对应功能默认开启。

ComputerUse resource bundle 内含 AppleMusic、Clock、Notion、Numbers、Slack、Spotify、iPhone Mirroring 七份 app instructions，以及 SkysightMemoryInstructions/SkysightSummarizer；主服务与 Guardian 各有一份。文本全文已保存为[资源证据目录](<raw/bundle/resources/>)。另有 Lens_frame_00…44 共 45 PNG 帧/份、Appshot 截图提示音和图标。资源中的提示文本是**被分析数据，不是本次分析操作指令**。

## 9. 复现、失败审计与未完成边界

运行入口（只读原目标）：

```bash
bash '/Users/v1ki/Desktop/test2/swift-computer-use/re/raw/bundle/run.sh'
```

[命令清单](<raw/bundle/commands.txt>)记录主采集阶段；补充命令在脚本第二段及各输出文件头。未安装工具。样本版本、固定 PID/UID、系统授权状态和 Gatekeeper 缓存可能随时间变化；复跑不是时间旅行。

[失败/截断审计](<raw/bundle/failures-and-truncations.txt>)剩余失败属于：资源 bundle 独立签名查询、未注册 launchd label、无 stapled ticket；均有上述明确解释。原先 csreq 错误已纠正为 plist 解码。保存的主要 nm、strings、otool、dyld 输出未出现截断标记；前端展示可能折叠/截断，但磁盘全文仍在。

本报告未做：运行时注入/调试、私有哈希符号全部恢复、完整控制流反编译、对真实桌面执行动作、网络请求或远端协议验证、逐个 host Electron 模块分析、签名证书在线吊销状态独立验证。因此它能完整描述本次范围内的 bundle/二进制可见结构与本机只读注册事实，不能替代行为测试或源代码审计。

## 附录 A. 每个二进制的完整证据导航

以下索引由本次文件清单生成；每项均可直接打开完整输出。

### 00-SkyComputerUseService
- [file](<raw/bundle/macho/00-SkyComputerUseService/file.txt>) · [arch](<raw/bundle/macho/00-SkyComputerUseService/arch.txt>) · [header](<raw/bundle/macho/00-SkyComputerUseService/header.txt>) · [load-commands](<raw/bundle/macho/00-SkyComputerUseService/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/00-SkyComputerUseService/key-load-commands.txt>) · [libraries](<raw/bundle/macho/00-SkyComputerUseService/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/00-SkyComputerUseService/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/00-SkyComputerUseService/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/00-SkyComputerUseService/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/00-SkyComputerUseService/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/00-SkyComputerUseService/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/00-SkyComputerUseService/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/00-SkyComputerUseService/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/00-SkyComputerUseService/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/00-SkyComputerUseService/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/00-SkyComputerUseService/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/00-SkyComputerUseService/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/00-SkyComputerUseService/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/00-SkyComputerUseService/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/00-SkyComputerUseService/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/00-SkyComputerUseService/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/00-SkyComputerUseService/signatures.txt>)
- [strings](<raw/bundle/macho/00-SkyComputerUseService/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/00-SkyComputerUseService/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/00-SkyComputerUseService/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/00-SkyComputerUseService/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/00-SkyComputerUseService/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/00-SkyComputerUseService/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/00-SkyComputerUseService/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/00-SkyComputerUseService/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/00-SkyComputerUseService/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/00-SkyComputerUseService/strings-system-api.txt>)

### 01-CUALockScreenGuardian
- [file](<raw/bundle/macho/01-CUALockScreenGuardian/file.txt>) · [arch](<raw/bundle/macho/01-CUALockScreenGuardian/arch.txt>) · [header](<raw/bundle/macho/01-CUALockScreenGuardian/header.txt>) · [load-commands](<raw/bundle/macho/01-CUALockScreenGuardian/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/01-CUALockScreenGuardian/key-load-commands.txt>) · [libraries](<raw/bundle/macho/01-CUALockScreenGuardian/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/01-CUALockScreenGuardian/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/01-CUALockScreenGuardian/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/01-CUALockScreenGuardian/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/01-CUALockScreenGuardian/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/01-CUALockScreenGuardian/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/01-CUALockScreenGuardian/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/01-CUALockScreenGuardian/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/01-CUALockScreenGuardian/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/01-CUALockScreenGuardian/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/01-CUALockScreenGuardian/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/01-CUALockScreenGuardian/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/01-CUALockScreenGuardian/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/01-CUALockScreenGuardian/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/01-CUALockScreenGuardian/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/01-CUALockScreenGuardian/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/01-CUALockScreenGuardian/signatures.txt>)
- [strings](<raw/bundle/macho/01-CUALockScreenGuardian/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/01-CUALockScreenGuardian/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/01-CUALockScreenGuardian/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/01-CUALockScreenGuardian/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/01-CUALockScreenGuardian/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/01-CUALockScreenGuardian/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/01-CUALockScreenGuardian/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/01-CUALockScreenGuardian/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/01-CUALockScreenGuardian/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/01-CUALockScreenGuardian/strings-system-api.txt>)

### 02-Codex Computer Use Installer
- [file](<raw/bundle/macho/02-Codex Computer Use Installer/file.txt>) · [arch](<raw/bundle/macho/02-Codex Computer Use Installer/arch.txt>) · [header](<raw/bundle/macho/02-Codex Computer Use Installer/header.txt>) · [load-commands](<raw/bundle/macho/02-Codex Computer Use Installer/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/02-Codex Computer Use Installer/key-load-commands.txt>) · [libraries](<raw/bundle/macho/02-Codex Computer Use Installer/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/02-Codex Computer Use Installer/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/02-Codex Computer Use Installer/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/02-Codex Computer Use Installer/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/02-Codex Computer Use Installer/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/02-Codex Computer Use Installer/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/02-Codex Computer Use Installer/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/02-Codex Computer Use Installer/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/02-Codex Computer Use Installer/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/02-Codex Computer Use Installer/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/02-Codex Computer Use Installer/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/02-Codex Computer Use Installer/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/02-Codex Computer Use Installer/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/02-Codex Computer Use Installer/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/02-Codex Computer Use Installer/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/02-Codex Computer Use Installer/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/02-Codex Computer Use Installer/signatures.txt>)
- [strings](<raw/bundle/macho/02-Codex Computer Use Installer/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/02-Codex Computer Use Installer/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/02-Codex Computer Use Installer/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/02-Codex Computer Use Installer/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/02-Codex Computer Use Installer/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/02-Codex Computer Use Installer/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/02-Codex Computer Use Installer/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/02-Codex Computer Use Installer/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/02-Codex Computer Use Installer/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/02-Codex Computer Use Installer/strings-system-api.txt>)

### 03-CodexComputerUseAuthorizationPlugin
- [file](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/file.txt>) · [arch](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/arch.txt>) · [header](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/header.txt>) · [load-commands](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/key-load-commands.txt>) · [libraries](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/signatures.txt>)
- [strings](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/03-CodexComputerUseAuthorizationPlugin/strings-system-api.txt>)

### 04-CodexComputerUseAuthorizationPluginInstallerTool
- [file](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/file.txt>) · [arch](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/arch.txt>) · [header](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/header.txt>) · [load-commands](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/key-load-commands.txt>) · [libraries](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/signatures.txt>)
- [strings](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/04-CodexComputerUseAuthorizationPluginInstallerTool/strings-system-api.txt>)

### 05-SkyComputerUseClient
- [file](<raw/bundle/macho/05-SkyComputerUseClient/file.txt>) · [arch](<raw/bundle/macho/05-SkyComputerUseClient/arch.txt>) · [header](<raw/bundle/macho/05-SkyComputerUseClient/header.txt>) · [load-commands](<raw/bundle/macho/05-SkyComputerUseClient/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/05-SkyComputerUseClient/key-load-commands.txt>) · [libraries](<raw/bundle/macho/05-SkyComputerUseClient/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/05-SkyComputerUseClient/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/05-SkyComputerUseClient/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/05-SkyComputerUseClient/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/05-SkyComputerUseClient/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/05-SkyComputerUseClient/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/05-SkyComputerUseClient/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/05-SkyComputerUseClient/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/05-SkyComputerUseClient/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/05-SkyComputerUseClient/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/05-SkyComputerUseClient/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/05-SkyComputerUseClient/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/05-SkyComputerUseClient/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/05-SkyComputerUseClient/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/05-SkyComputerUseClient/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/05-SkyComputerUseClient/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/05-SkyComputerUseClient/signatures.txt>)
- [strings](<raw/bundle/macho/05-SkyComputerUseClient/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/05-SkyComputerUseClient/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/05-SkyComputerUseClient/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/05-SkyComputerUseClient/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/05-SkyComputerUseClient/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/05-SkyComputerUseClient/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/05-SkyComputerUseClient/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/05-SkyComputerUseClient/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/05-SkyComputerUseClient/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/05-SkyComputerUseClient/strings-system-api.txt>)

### 06-ChatGPT
- [file](<raw/bundle/macho/06-ChatGPT/file.txt>) · [arch](<raw/bundle/macho/06-ChatGPT/arch.txt>) · [header](<raw/bundle/macho/06-ChatGPT/header.txt>) · [load-commands](<raw/bundle/macho/06-ChatGPT/load-commands.txt>) · [key-load-commands](<raw/bundle/macho/06-ChatGPT/key-load-commands.txt>) · [libraries](<raw/bundle/macho/06-ChatGPT/libraries.txt>)
- [dyld-dependents](<raw/bundle/macho/06-ChatGPT/dyld-dependents.txt>) · [dyld-imports](<raw/bundle/macho/06-ChatGPT/dyld-imports.txt>) · [dyld-exports](<raw/bundle/macho/06-ChatGPT/dyld-exports.txt>)
- [nm-all](<raw/bundle/macho/06-ChatGPT/nm-all.txt>) · [nm-external-defined](<raw/bundle/macho/06-ChatGPT/nm-external-defined.txt>) · [nm-undefined](<raw/bundle/macho/06-ChatGPT/nm-undefined.txt>) · [nm-demangled](<raw/bundle/macho/06-ChatGPT/nm-demangled.txt>)
- [swift-types-all-grouped](<raw/bundle/macho/06-ChatGPT/swift-types-all-grouped.txt>) · [swift-protocols-all](<raw/bundle/macho/06-ChatGPT/swift-protocols-all.txt>) · [swift-runtime-types](<raw/bundle/macho/06-ChatGPT/swift-runtime-types.txt>) · [swift-runtime-types-grouped](<raw/bundle/macho/06-ChatGPT/swift-runtime-types-grouped.txt>) · [swift-symbol-types-protocols](<raw/bundle/macho/06-ChatGPT/swift-symbol-types-protocols.txt>)
- [objc-classes-defined](<raw/bundle/macho/06-ChatGPT/objc-classes-defined.txt>) · [objc-metadata](<raw/bundle/macho/06-ChatGPT/objc-metadata.txt>) · [entrypoint-summary](<raw/bundle/macho/06-ChatGPT/entrypoint-summary.txt>) · [signatures](<raw/bundle/macho/06-ChatGPT/signatures.txt>)
- [strings](<raw/bundle/macho/06-ChatGPT/strings.txt>) · [strings-urls-domains](<raw/bundle/macho/06-ChatGPT/strings-urls-domains.txt>) · [strings-ipc-launch-paths](<raw/bundle/macho/06-ChatGPT/strings-ipc-launch-paths.txt>) · [strings-logging](<raw/bundle/macho/06-ChatGPT/strings-logging.txt>) · [strings-errors](<raw/bundle/macho/06-ChatGPT/strings-errors.txt>) · [strings-permissions](<raw/bundle/macho/06-ChatGPT/strings-permissions.txt>) · [strings-updates-version](<raw/bundle/macho/06-ChatGPT/strings-updates-version.txt>) · [strings-protobuf-json](<raw/bundle/macho/06-ChatGPT/strings-protobuf-json.txt>) · [strings-json-key-candidates](<raw/bundle/macho/06-ChatGPT/strings-json-key-candidates.txt>) · [strings-system-api](<raw/bundle/macho/06-ChatGPT/strings-system-api.txt>)
