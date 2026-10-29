import AppKit
import ApplicationServices
import CUACore

/// WeChat 4.x AX adapter. No mouse, activation, clipboard, or global events.
/// Synchronous execution on SkyEngine deliberately prevents interleaved input.
private final class BackgroundChat {
    let pid: pid_t
    let initialPID: pid_t
    let root: AXUIElement
    var evidence: [String] = []
    init(app: String) throws {
        guard app == "com.tencent.xinWeChat" else { throw CUAError(code: .unsupported, message: "Chat adapter currently supports WeChat only") }
        try AXAccess.checkPermission()
        pid = try AppCatalog.running(app).processIdentifier
        root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.3)
        initialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        try check("begin")
    }
    func check(_ phase: String) throws {
        try Task.checkCancellation()
        let front = NSWorkspace.shared.frontmostApplication
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(phase) frontmost=\(front?.localizedName ?? "unknown") PID=\(front?.processIdentifier ?? -1)"
        evidence.append(line)
        // Both public macOS views are sampled at each primitive boundary.
        let observer = Process()
        observer.executableURL = URL(fileURLWithPath:"/usr/bin/osascript")
        observer.arguments = ["-e", "tell application \"System Events\"", "-e", "set p to first application process whose frontmost is true", "-e", "return {name of p, unix id of p}", "-e", "end tell"]
        let pipe = Pipe(); observer.standardOutput = pipe; observer.standardError = pipe
        try observer.run(); observer.waitUntilExit()
        let observed = String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        evidence.append("\(phase) System Events=\(observed)")
        guard observer.terminationStatus == 0, observed.hasSuffix(", \(initialPID)") else {
            throw CUAError(code:.inputRejected,message:"System Events foreground observation failed or changed",data:.object(["evidence":.array(evidence.map(JSONValue.string))]))
        }
        guard initialPID > 0, front?.processIdentifier == initialPID, initialPID != pid else {
            throw CUAError(code: .inputRejected, message: "Foreground changed or WeChat is frontmost; stopped", data: .object(["evidence": .array(evidence.map(JSONValue.string))]))
        }
    }
    func primitive(_ label: String, _ body: () throws -> Void) throws {
        try check("before \(label)")
        do { try body() } catch { try check("after failed \(label)"); throw error }
        usleep(100_000)
        try check("after \(label)")
    }
    func str(_ e: AXUIElement, _ attr: String) -> String { AXAccess.value(e, attr) as? String ?? "" }
    func children(_ e: AXUIElement) -> [AXUIElement] { AXAccess.value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    func nodes(_ e: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 20 else { return [] }
        return [e] + children(e).prefix(1500).flatMap { nodes($0, depth: depth + 1) }
    }
    var windows: [AXUIElement] { AXAccess.value(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
    func composer(_ window: AXUIElement, name: String) -> AXUIElement? {
        nodes(window).first {
            str($0,kAXRoleAttribute) == "AXTextArea" &&
            (str($0,kAXTitleAttribute) == name || (str(window,kAXTitleAttribute) == name && str($0,kAXTitleAttribute) == "输入"))
        }
    }
    func chatWindow(_ name: String) -> AXUIElement? {
        windows.first { composer($0, name: name) != nil && messageList($0) != nil }
    }
    func messageList(_ window: AXUIElement) -> AXUIElement? {
        nodes(window).first { str($0,kAXRoleAttribute) == "AXList" && str($0,kAXTitleAttribute) == "消息" }
    }
    func focus(_ element: AXUIElement) throws {
        try primitive("AXFocused=true") {
            try AXAccess.check(AXUIElementSetAttributeValue(element,kAXFocusedAttribute as CFString,kCFBooleanTrue),context:"Focus")
            guard let focused = AXAccess.element(AXAccess.value(root,kAXFocusedUIElementAttribute)), CFEqual(focused,element) else {
                throw CUAError(code:.inputRejected,message:"AX focus read-back mismatch")
            }
        }
    }
    func set(_ element: AXUIElement, _ text: String) throws {
        try primitive("AXValue write") {
            try AXAccess.check(AXUIElementSetAttributeValue(element,kAXValueAttribute as CFString,text as CFString),context:"Set text")
            guard str(element,kAXValueAttribute) == text else { throw CUAError(code:.inputRejected,message:"AX value read-back mismatch") }
        }
    }
    func key(_ value: String) throws {
        try primitive("CGEventPostToPid \(value)") { try InputSynthesis.key(KeyChord.parse(value),pid:pid) }
    }
    func search(_ text: String) throws {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CUAError.invalidParams("Empty search",method:"searchText") }
        guard let field = windows.flatMap({ nodes($0) }).first(where: { str($0,kAXRoleAttribute) == "AXTextArea" && str($0,kAXTitleAttribute) == "搜索" }) else {
            throw CUAError(code:.elementNotFound,message:"Background AX search field unavailable; will not activate")
        }
        try set(field,text); try focus(field)
        // Force change notification without relying on AXValue notifying Qt/AppKit.
        try key("End"); try key("Space"); try key("BackSpace")
        usleep(350_000)
        guard str(field,kAXValueAttribute) == text else { throw CUAError(code:.inputRejected,message:"Search text changed unexpectedly") }
    }
    func open(_ name: String) throws -> AXUIElement {
        guard !name.isEmpty else { throw CUAError.invalidParams("Empty chat name",method:"openChat") }
        if let w = chatWindow(name) { try check("existing exact chat"); return w }
        try search(name)
        if let w = chatWindow(name) { return w }
        // Search may expose a separate AXWindow or replace the conversation list.
        // Only press a unique exact result, never a substring match.
        let rows = windows.flatMap { nodes($0) }.filter { str($0,kAXRoleAttribute) == "AXStaticText" && str($0,kAXTitleAttribute).components(separatedBy:"\n").first == name }
        let index = try ChatSafety.matchingRow(rows.map { str($0,kAXTitleAttribute) },name:name)
        try primitive("AXPress exact result") {
            try AXAccess.check(AXUIElementPerformAction(rows[index],kAXPressAction as CFString),context:"Press exact result")
        }
        if let w = chatWindow(name) { return w }
        // Return is safe only while focus remains on search, never a composer.
        guard let focused = AXAccess.element(AXAccess.value(root,kAXFocusedUIElementAttribute)), str(focused,kAXTitleAttribute) == "搜索" else {
            throw CUAError(code:.inputRejected,message:"Search lost focus; refusing Return")
        }
        try key("Down")
        guard let focused = AXAccess.element(AXAccess.value(root,kAXFocusedUIElementAttribute)), str(focused,kAXTitleAttribute) == "搜索" || str(focused,kAXRoleAttribute) == "AXList" else {
            throw CUAError(code:.inputRejected,message:"Unsafe focus after Down; refusing Return")
        }
        guard !windows.flatMap({ nodes($0) }).contains(where: {
            str($0,kAXRoleAttribute) == "AXTextArea" && str($0,kAXTitleAttribute) != "搜索" && !str($0,kAXValueAttribute).isEmpty
        }) else { throw CUAError(code:.inputRejected,message:"A chat draft exists; refusing navigation Return") }
        try key("Return")
        for _ in 0..<10 { try check("verify open"); if let w = chatWindow(name) { return w }; usleep(100_000) }
        throw CUAError(code:.inputRejected,message:"Background open had no verified effect; no activation fallback",data:.object(["evidence":.array(evidence.map(JSONValue.string))]))
    }
    func messages(_ window: AXUIElement) -> [ChatMessage] {
        guard let list = messageList(window) else { return [] }
        return children(list).compactMap { row in
            let title = str(row,kAXTitleAttribute)
            let value = str(row,kAXValueAttribute)
            let text = title.isEmpty ? value : title
            guard !text.isEmpty else { return nil }
            // Keep the complete AX label: sender is nil when WeChat does not expose it.
            return ChatMessage(text:text)
        }
    }
    func result(_ name: String, window: AXUIElement, limit: Int?) throws -> ChatResult {
        try check("read verified message list")
        return ChatResult(chat:name,windowTitle:str(window,kAXTitleAttribute),messages:Array(messages(window).suffix(max(1,min(limit ?? 12,100)))),evidence:evidence)
    }
    func send(_ params: ChatParams) throws -> ChatResult {
        guard let name = params.chat, let text = params.text, !text.isEmpty else { throw CUAError.invalidParams("send requires chat and nonempty text",method:"sendText") }
        try ChatSafety.validateSend(chat:name,title:name) // Reject before navigation or any mutation.
        let window = try open(name)
        guard let field = composer(window,name:name) else { throw CUAError(code:.elementNotFound,message:"Composer missing") }
        try ChatSafety.validateSend(chat:name,title:str(window,kAXTitleAttribute) == name ? str(window,kAXTitleAttribute) : str(field,kAXTitleAttribute))
        guard str(field,kAXValueAttribute).isEmpty else { throw CUAError(code:.inputRejected,message:"Refusing to overwrite existing draft") }
        let before = messages(window).map(\.text)
        try set(field,text); try focus(field)
        try ChatSafety.validateSend(chat:name,title:str(window,kAXTitleAttribute) == name ? str(window,kAXTitleAttribute) : str(field,kAXTitleAttribute))
        guard chatWindow(name) != nil, str(field,kAXValueAttribute) == text else { throw CUAError(code:.inputRejected,message:"Target changed before send") }
        try key("Return") // Never retry: timeout may mean delivery status unknown.
        for _ in 0..<15 {
            try check("verify send")
            if ChatSafety.verifiedSend(before:before,after:messages(window).map(\.text),text:text,composer:str(field,kAXValueAttribute)) { return try result(name,window:window,limit:params.limit) }
            usleep(100_000)
        }
        throw CUAError(code:.inputRejected,message:"Send not verified; delivery unknown, do not automatically retry",data:.object(["evidence":.array(evidence.map(JSONValue.string))]))
    }
}

extension SkyEngine {
    public func searchText(_ params: ChatParams) async throws -> ChatResult {
        try InputSynthesis.$context.withValue(InputContext(allowActivation:false)) {
            let adapter = try BackgroundChat(app:params.app)
            try adapter.search(params.text ?? params.name ?? "")
            return ChatResult(chat:params.text ?? params.name ?? "",windowTitle:"",messages:[],evidence:adapter.evidence,verified:false)
        }
    }
    public func openChat(_ params: ChatParams) async throws -> ChatResult {
        try InputSynthesis.$context.withValue(InputContext(allowActivation:false)) {
            let adapter = try BackgroundChat(app:params.app); let name = params.name ?? params.chat ?? ""
            let window = try adapter.open(name)
            return try adapter.result(name,window:window,limit:params.limit)
        }
    }
    public func readChat(_ params: ChatParams) async throws -> ChatResult {
        try InputSynthesis.$context.withValue(InputContext(allowActivation:false)) {
            let adapter = try BackgroundChat(app:params.app); let name = params.name ?? params.chat ?? ""
            guard let window = adapter.chatWindow(name) else { throw CUAError(code:.elementNotFound,message:"Exact chat is not open") }
            return try adapter.result(name,window:window,limit:params.limit)
        }
    }
    public func sendText(_ params: ChatParams) async throws -> ChatResult {
        try InputSynthesis.$context.withValue(InputContext(allowActivation:false)) { try BackgroundChat(app:params.app).send(params) }
    }
}
