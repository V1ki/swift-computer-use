import Foundation
import AppKit
import ApplicationServices
import CUACore

/// 真正的系统引擎。actor 使用通用执行器，AX/CG 同步调用不占 MainActor。
public actor SkyEngine: CUAEngine {
    private var snapshots: [String: AXSnapshot] = [:]
    private var installedApps: [CUAAppInfo] = []
    private var installedAt = Date.distantPast
    private var generation: UInt64 = 0

    public init() {}

    public func permissions() async -> CUAPermissions {
        CUAPermissions(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }

    public func launchApp(_ app: String) async throws {
        if (try? AppCatalog.running(app)) != nil { return }
        let url: URL?
        if app.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: app)
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        } else { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) }
        guard let url else { throw CUAError(code: .appNotFound, message: "Cannot locate application '\(app)'") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config) }
        catch { throw CUAError(code: .internalError, message: "Cannot launch \(app): \(error.localizedDescription)") }
    }

    public func listApps(includeWindows: Bool) async throws -> [CUAAppInfo] {
        if Date().timeIntervalSince(installedAt) > 60 {
            installedApps = AppCatalog.installed(); installedAt = Date()
        }
        var result = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.id, $0) })
        let windows = includeWindows ? AppCatalog.windows() : []
        for running in NSWorkspace.shared.runningApplications where !running.isTerminated {
            let id = AppCatalog.identifier(running)
            // macOS 不提供公开的精确使用次数；不伪造 useCount 或将启动时间冒充 lastUsedDate。
            result[id] = CUAAppInfo(id: id, displayName: running.localizedName ?? result[id]?.displayName,
                                    isRunning: true, windows: windows.filter { $0.app == id })
        }
        return result.values.sorted { ($0.displayName ?? $0.id).localizedCaseInsensitiveCompare($1.displayName ?? $1.id) == .orderedAscending }
    }

    public func listWindows() async throws -> [CUAWindowInfo] { AppCatalog.windows() }

    public func getAppState(_ params: GetAppStateParams) async throws -> CUAAppState {
        let running = try AppCatalog.running(params.app)
        let app = AppCatalog.identifier(running)
        let allWindows = AppCatalog.windows().filter { $0.app == app }
        // 1×1 helper / 离屏 back-buffer 窗口会污染 app state，只在 listWindows 里保留。
        let visibleWindows = allWindows.filter { $0.bounds.width > 200 && $0.bounds.height > 100 }
        // 每次调用都使旧表失效（即使本次只要截图）。全量文本是默认行为，disableDiff 暂不做增量。
        snapshots[app] = nil
        let currentGeneration = generation
        let wantText = params.includeText ?? true
        let wantScreenshot = params.includeScreenshot ?? true
        let requested = params.windowId.flatMap { id in allWindows.first { $0.id == id } }

        // 先读 AX 根节点：它的 frame 是把公开 AX 窗口映射回窗口服务器条目的可靠桥梁
        // （公开 AX API 不暴露 CGWindowID）。
        var snapshot: AXSnapshot?
        if wantText {
            snapshot = try AccessibilityCapture().capture(pid: running.processIdentifier, window: requested)
        }
        let target = requested
            ?? snapshot?.rootFrame.flatMap { AppCatalog.window(matching: $0, app: app, windows: allWindows) }
            ?? (try? AppCatalog.targetWindow(app: app, windowID: nil, windows: allWindows))

        var state = CUAAppState(app: app, windows: visibleWindows)
        if wantText, let snapshot {
            guard generation == currentGeneration else { throw CUAError(code: .elementIndexStale, message: "Session reset during capture") }
            snapshots[app] = snapshot
            let nodes = AXFormat.filter(snapshot.nodes, query: params.query)
            let title = snapshot.rootTitle ?? target?.title
            let tree = AXFormat.render(nodes, windowTitle: title, truncated: snapshot.truncated)
            var focused: String?, selected: [String] = []
            func inspect(_ node: CUAAccessibilityNode) {
                if node.states.contains("focused") { focused = "[\(node.index)] \(node.title ?? node.role)" }
                if node.states.contains("selected") { selected.append("[\(node.index)] \(node.title ?? node.role)") }
                node.children.forEach(inspect)
            }
            nodes.forEach(inspect)
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.12)
            let focusedElement = AXAccess.element(AXAccess.value(axApp, kAXFocusedUIElementAttribute))
            let selectedText = focusedElement.flatMap { AXAccess.value($0, kAXSelectedTextAttribute) as? String }
            state.accessibility = CUAAccessibilityState(tree: tree, focusedElement: focused, selectedText: selectedText,
                                                        selectedElements: selected.isEmpty ? nil : selected)
            state.text = "App: \(running.localizedName ?? app) (\(app))\n" + tree
        }
        if wantScreenshot {
            guard let target else { throw CUAError(code: .elementNotFound, message: "Application has no capturable window") }
            state.screenshot = try await ScreenCapture.capture(
                CaptureScreenshotParams(app: app, windowId: target.id), windows: allWindows
            ).first
        }
        return state
    }

    public func captureScreenshot(_ params: CaptureScreenshotParams) async throws -> [CUAScreenshot] {
        var canonical = params
        if let app = params.app {
            let running = try AppCatalog.running(app)
            let id = AppCatalog.identifier(running)
            canonical.app = id
            if canonical.windowId == nil {
                canonical.windowId = try AppCatalog.targetWindow(app: id, windowID: nil, windows: AppCatalog.windows()).id
            }
        }
        return try await ScreenCapture.capture(canonical, windows: AppCatalog.windows())
    }

    public func resetSessionState() async {
        snapshots.removeAll()
        installedApps.removeAll(); installedAt = .distantPast
        generation &+= 1
    }

    private func resolve(_ app: NSRunningApplication, index: Int, windowID: UInt32?) throws -> AXUIElement {
        let id = AppCatalog.identifier(app)
        guard let snapshot = snapshots[id] else { throw CUAError(code: .elementIndexStale, message: "Call getAppState before using element indices") }
        try snapshot.stamp.validate(pid: app.processIdentifier, windowID: windowID)
        let element = try IndexStamp.requireIndex(index, in: snapshot.elements)
        var pid: pid_t = 0
        try AXAccess.check(AXUIElementGetPid(element, &pid), context: "Resolve index")
        guard pid == app.processIdentifier else { throw CUAError(code: .elementIndexStale, message: "Element belongs to an old process") }
        return element
    }

    private func prepare(_ id: String, windowID: UInt32?) throws -> NSRunningApplication {
        try AXAccess.checkPermission()
        let app = try AppCatalog.running(id)
        let canonical = AppCatalog.identifier(app)
        let target: CUAWindowInfo?
        if let windowID { target = try AppCatalog.targetWindow(app: canonical, windowID: windowID, windows: AppCatalog.windows()) }
        else { target = nil }
        _ = app.activate(options: [])
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        _ = AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let target {
            let window = try AXAccess.window(pid: app.processIdentifier, target: target)
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if !app.isActive { InputSynthesis.pause(80) }
        guard app.isActive else { throw CUAError(code: .inputRejected, message: "Cannot activate target app") }
        return app
    }

    private func point(app: NSRunningApplication, index: Int?, x: Double?, y: Double?, windowID: UInt32?) throws -> CGPoint {
        if let index {
            let element = try resolve(app, index: index, windowID: windowID)
            guard let frame = AXAccess.frame(element), frame.width > 0, frame.height > 0 else {
                throw CUAError(code: .elementNotFound, message: "Element has no usable frame")
            }
            return Coordinates.center(frame)
        }
        let window = try AppCatalog.targetWindow(app: AppCatalog.identifier(app), windowID: windowID, windows: AppCatalog.windows())
        guard (x == nil) == (y == nil), x?.isFinite != false, y?.isFinite != false else {
            throw CUAError.invalidParams("x and y must be supplied together and finite", method: "input")
        }
        return Coordinates.global(CUAPoint(x: x ?? window.bounds.width / 2, y: y ?? window.bounds.height / 2), in: window.bounds)
    }

    private func focus(_ element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if result != .success {
            guard let frame = AXAccess.frame(element) else { try AXAccess.check(result, context: "Focus element"); return }
            try InputSynthesis.click(at: Coordinates.center(frame), button: .left, count: 1, flags: [], duration: 20)
        }
    }

    public func click(_ params: ClickParams) async throws {
        guard let button = CUAMouseButton.parse(params.mouseButton ?? "left") else { throw CUAError.invalidParams("Invalid mouse button", method: "click") }
        let duration = try InputSynthesis.duration(params.durationMilliseconds)
        let count = params.clickCount ?? 1
        guard (1...10).contains(count) else { throw CUAError.invalidParams("clickCount must be 1...10", method: "click") }
        var flags: CGEventFlags = []
        if let key = params.key {
            if let modifier = KeyChord.modifier(key) { flags = modifier }
            else { flags = try KeyChord.parse(key).flags }
        }
        let app = try prepare(params.app, windowID: params.windowId)
        if let index = params.elementIndex, params.key == nil, button == .left, count == 1, params.durationMilliseconds == nil {
            let element = try resolve(app, index: index, windowID: params.windowId)
            let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if status == .success { return }
            if status == .invalidUIElement || status == .cannotComplete { try AXAccess.check(status, context: "Press element") }
        }
        let location = try point(app: app, index: params.elementIndex, x: params.x, y: params.y, windowID: params.windowId)
        try InputSynthesis.click(at: location, button: button, count: count, flags: flags, duration: duration)
    }

    public func pressKey(_ params: PressKeyParams) async throws {
        let chord = try KeyChord.parse(params.key)
        let duration = try InputSynthesis.duration(params.durationMilliseconds)
        _ = try prepare(params.app, windowID: params.windowId)
        try InputSynthesis.key(chord, duration: duration)
    }

    public func typeText(_ params: TypeTextParams) async throws {
        let app = try prepare(params.app, windowID: params.windowId)
        if let index = params.elementIndex { try focus(resolve(app, index: index, windowID: params.windowId)) }
        try InputSynthesis.text(params.text)
    }

    public func scroll(_ params: ScrollParams) async throws {
        let app = try prepare(params.app, windowID: params.windowId)
        let location = try point(app: app, index: params.elementIndex, x: params.x, y: params.y, windowID: params.windowId)
        var dx = params.scrollX ?? 0, dy = params.scrollY ?? 0
        if let raw = params.direction {
            guard let direction = CUAScrollDirection.parse(raw) else { throw CUAError.invalidParams("Invalid scroll direction", method: "scroll") }
            let window = try AppCatalog.targetWindow(app: AppCatalog.identifier(app), windowID: params.windowId, windows: AppCatalog.windows())
            let extent = direction == .left || direction == .right ? window.bounds.width : window.bounds.height
            let amount = params.pixels ?? ((params.pages ?? 1) * extent * 0.85)
            switch direction {
            case .up: dy = -amount
            case .down: dy = amount
            case .left: dx = -amount
            case .right: dx = amount
            }
        }
        guard dx.isFinite, dy.isFinite, abs(dx) <= 1_000_000, abs(dy) <= 1_000_000 else { throw CUAError.invalidParams("Scroll deltas are out of range", method: "scroll") }
        try InputSynthesis.mouse(.mouseMoved, at: location)
        // CG 的正值是上/左；协议的正值是下/右。
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0)
        event?.location = location
        try InputSynthesis.post(event)
    }

    public func setValue(_ params: SetValueParams) async throws {
        let app = try prepare(params.app, windowID: params.windowId)
        let element = try resolve(app, index: params.elementIndex, windowID: params.windowId)
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, params.value as CFString)
        if status == .success { return }
        if status == .invalidUIElement || status == .cannotComplete { try AXAccess.check(status, context: "Set value") }
        try focus(element)
        try InputSynthesis.key(KeyChord.parse("Cmd+a"))
        if params.value.isEmpty { try InputSynthesis.key(KeyChord.parse("BackSpace")) }
        else { try InputSynthesis.text(params.value) }
    }

    public func drag(_ params: DragParams) async throws {
        let app = try prepare(params.app, windowID: params.windowId)
        let start = try point(app: app, index: nil, x: params.fromX, y: params.fromY, windowID: params.windowId)
        let end = try point(app: app, index: nil, x: params.toX, y: params.toY, windowID: params.windowId)
        try InputSynthesis.mouse(.leftMouseDown, at: start)
        defer { try? InputSynthesis.mouse(.leftMouseUp, at: end) }
        for step in 1...30 {
            InputSynthesis.pause(15)
            let t = Double(step) / 30
            try InputSynthesis.mouse(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
    }

    public func paste(_ params: PasteParams) async throws {
        guard let format = CUAPasteFormat(rawValue: params.format ?? "text") else { throw CUAError.invalidParams("Invalid paste format", method: "paste") }
        _ = try prepare(params.app, windowID: params.windowId)
        try InputSynthesis.paste(params.text, format: format)
    }

    public func selectText(_ params: SelectTextParams) async throws {
        guard let type = CUASelectionType(rawValue: params.selectionType ?? "text") else { throw CUAError.invalidParams("Invalid selectionType", method: "selectText") }
        let app = try prepare(params.app, windowID: params.windowId)
        let element = try resolve(app, index: params.elementIndex, windowID: params.windowId)
        guard let source = AXAccess.value(element, kAXValueAttribute) as? String else { throw CUAError(code: .inputRejected, message: "Element has no readable text") }
        var range = try TextInput.selection(in: source, text: params.text, prefix: params.prefix, suffix: params.suffix, type: type)
        try focus(element)
        if let value = AXValueCreate(.cfRange, &range) {
            let status = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            if status == .success { return }
            if status == .invalidUIElement || status == .cannotComplete { try AXAccess.check(status, context: "Select text") }
        }
        // 回退按 grapheme 移动光标，而非将 UTF-16 代理对误算成两次方向键。
        let ns = source as NSString
        let before = ns.substring(to: range.location).count
        let count = ns.substring(with: NSRange(location: range.location, length: range.length)).count
        guard before + count <= 4000 else { throw CUAError(code: .inputRejected, message: "Keyboard selection fallback exceeds 4000 characters") }
        try InputSynthesis.key(KeyChord.parse("Cmd+Home"))
        for _ in 0..<before { try InputSynthesis.key(KeyChord.parse("Right"), duration: 0) }
        for _ in 0..<count { try InputSynthesis.key(KeyChord.parse("Shift+Right"), duration: 0) }
    }

    public func performSecondaryAction(_ params: PerformSecondaryActionParams) async throws {
        let app = try prepare(params.app, windowID: params.windowId)
        let element = try resolve(app, index: params.elementIndex, windowID: params.windowId)
        let action = AXAccess.actions(element).first { $0.caseInsensitiveCompare(params.action) == .orderedSame } ?? params.action
        try AXAccess.check(AXUIElementPerformAction(element, action as CFString), context: "Perform \(action)")
    }
}
