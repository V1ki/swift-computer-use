import Foundation
import ApplicationServices
import CUACore

/// AXUIElement references are not Sendable, but the snapshot never leaves the
/// engine actor; @unchecked is required for older Swift 6.x toolchains that
/// still flag region-based isolation on actor-local values.
struct AXSnapshot: @unchecked Sendable {
    var stamp: IndexStamp
    var elements: [Int: AXUIElement]
    var nodes: [CUAAccessibilityNode]
    var truncated: Bool
    var rootTitle: String?
    var rootFrame: CUARect?
    var rootRole: String?

    /// True when the capture actually started at an AXWindow. Lazy apps such as
    /// WeChat return the AXApplication element (children = menu bars) until the
    /// app has been activated at least once.
    var hasWindowRoot: Bool { rootRole == "AXWindow" || rootRole == "AXSheet" || rootRole == "AXDialog" }
}

enum AXAccess {
    static func checkPermission() throws {
        guard AXIsProcessTrusted() else { throw CUAError.permissionMissing("Accessibility") }
    }
    static func check(_ error: AXError, context: String) throws {
        guard error != .success else { return }
        let code: CUAErrorCode
        switch error {
        case .cannotComplete: code = .timeout
        case .invalidUIElement: code = .elementIndexStale
        case .apiDisabled: throw CUAError.permissionMissing("Accessibility")
        default: code = .inputRejected
        }
        throw CUAError(code: code, message: "\(context): AX error \(error.rawValue)")
    }
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    static func frame(_ element: AXUIElement) -> CUARect? {
        frame(position: value(element, kAXPositionAttribute), size: value(element, kAXSizeAttribute))
    }
    static func frame(position: CFTypeRef?, size: CFTypeRef?) -> CUARect? {
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = unsafeDowncast(position, to: AXValue.self), s = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
              AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite else { return nil }
        return CUARect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }
    /// Number of AX windows currently exposed by the app.
    static func windowCount(pid: Int32) -> Int {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return (value(app, kAXWindowsAttribute) as? [AXUIElement])?.count ?? 0
    }

    /// Chromium/Electron expose an "enhanced" accessibility mode behind these
    /// attributes; enabling them is the public-API equivalent of what the
    /// original service does (it keeps an AXEnablementAssertion alive).
    /// Returns true when a window became visible after enabling.
    /// Turns on Chromium/Electron accessibility if the app advertises the
    /// switch. Returns true when at least one switch was present, i.e. the tree
    /// may grow asynchronously — callers should re-capture and poll.
    ///
    /// The setter's return value is deliberately ignored: Electron returns
    /// -25208 / 0 inconsistently while the attribute still flips.
    @discardableResult
    static func enableAccessibilityIfNeeded(pid: Int32) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(app, &names) == .success,
              let attributes = names as? [String] else { return false }
        var attempted = false
        for flag in ["AXEnhancedUserInterface", "AXManualAccessibility"] where attributes.contains(flag) {
            attempted = true
            _ = AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue)
            let readBack = (value(app, flag) as? NSNumber)?.boolValue ?? false
            CUALogger(CUALog.engine).debug("enabling \(flag) for pid \(pid): readBack=\(readBack)")
        }
        return attempted
    }

    /// Frame of the app's main (or focused) window, without a full tree walk.
    /// Used to pick the right window-server entry instead of "largest window".
    static func primaryWindowFrame(pid: Int32) -> CUARect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.12)
        let window = element(value(app, kAXMainWindowAttribute)) ?? element(value(app, kAXFocusedWindowAttribute))
        return window.flatMap { frame($0) }
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }
    static func window(pid: Int32, target: CUAWindowInfo?) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw)
        if status == .cannotComplete { try check(status, context: "Read app windows") }
        let windows = raw as? [AXUIElement] ?? []
        if let target {
            // 公开 AX API 不暴露 CGWindowID；以全局 frame + title 匹配，不使用私有 _AXUIElementGetWindow。
            let deadline = ProcessInfo.processInfo.systemUptime + 0.6
            var geometryMatch: AXUIElement?
            for item in windows.prefix(100) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                AXUIElementSetMessagingTimeout(item, 0.05)
                guard let r = frame(item), abs(r.x - target.bounds.x) < 3, abs(r.y - target.bounds.y) < 3,
                      abs(r.width - target.bounds.width) < 3, abs(r.height - target.bounds.height) < 3 else { continue }
                if geometryMatch == nil { geometryMatch = item }
                if target.title?.isEmpty != false || value(item, kAXTitleAttribute) as? String == target.title { return item }
                if geometryMatch != nil { break }
            }
            if let geometryMatch { return geometryMatch }
            throw CUAError(code: .elementNotFound, message: "Requested window is not exposed in the app accessibility tree")
        }
        // 应用的主窗口/焦点窗口是公开属性，比外部传入的窗口几何更可靠。
        if let main = element(value(app, kAXMainWindowAttribute)) { return main }
        if let focused = element(value(app, kAXFocusedWindowAttribute)) { return focused }
        if let largest = windows.max(by: { lhs, rhs in
            let l = frame(lhs), r = frame(rhs)
            return (l?.width ?? 0) * (l?.height ?? 0) < (r?.width ?? 0) * (r?.height ?? 0)
        }) { return largest }
        if target != nil { throw CUAError(code: .elementNotFound, message: "Window is not exposed in the app accessibility tree") }
        return app
    }
}

/// 有界 DFS，元素引用只在引擎 actor 内持有；每次读取设置短超时。
final class AccessibilityCapture {
    let maxNodes = 6000
    let maxDepth = 40
    let deadline = ProcessInfo.processInfo.systemUptime + 2.5
    var elements: [Int: AXUIElement] = [:]
    var seen: [CFHashCode: [AXUIElement]] = [:]
    var truncated = false
    let attributes: [String] = [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute,
                                kAXIdentifierAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXSelectedAttribute,
                                kAXExpandedAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, "AXHidden", kAXSubroleAttribute]

    func capture(pid: Int32, window: CUAWindowInfo?) throws -> AXSnapshot {
        try AXAccess.checkPermission()
        let root = try AXAccess.window(pid: pid, target: window)
        let node = try visit(root, depth: 0)
        return AXSnapshot(stamp: IndexStamp(pid: pid, windowID: window?.id, capturedAt: Date()), elements: elements,
                          nodes: node.map { [$0] } ?? [], truncated: truncated,
                          rootTitle: AXAccess.value(root, kAXTitleAttribute) as? String,
                          rootFrame: AXAccess.frame(root),
                          rootRole: AXAccess.value(root, kAXRoleAttribute) as? String)
    }
    func visit(_ element: AXUIElement, depth: Int) throws -> CUAAccessibilityNode? {
        guard elements.count < maxNodes, depth <= maxDepth, ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; return nil }
        // 哈希桶加 CFEqual 防环，不能因哈希碰撞漏掉不同元素。
        let hash = CFHash(element)
        guard !(seen[hash] ?? []).contains(where: { CFEqual($0, element) }) else { return nil }
        seen[hash, default: []].append(element)
        AXUIElementSetMessagingTimeout(element, Float(min(0.12, max(0.01, deadline - ProcessInfo.processInfo.systemUptime))))
        var raw: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw)
        if status == .cannotComplete {
            if depth == 0 { try AXAccess.check(status, context: "Capture accessibility") }
            truncated = true
            return nil
        }
        guard status == .success, let values = raw as? [Any], values.count == attributes.count,
              let role = values[0] as? String, !role.isEmpty else { return nil }
        if values[12] as? Bool == true { return nil }
        let index = elements.count
        elements[index] = element
        var states: [String] = []
        for (offset, label) in [(5, "enabled"), (6, "focused"), (7, "selected"), (8, "expanded")] {
            if values[offset] as? Bool == true { states.append(label) }
        }
        if values[5] as? Bool == false { states.append("disabled") }
        var value = values[2] as? String
        if value == nil, let number = values[2] as? NSNumber { value = number.stringValue }
        // AXActions 不是标准属性，需单独使用公开 CopyActionNames。
        let actions = ProcessInfo.processInfo.systemUptime < deadline ? AXAccess.actions(element) : []
        var node = CUAAccessibilityNode(index: index, role: role, subrole: values[13] as? String, title: values[1] as? String,
                                        value: value.map { String($0.prefix(16_384)) }, description: values[3] as? String,
                                        identifier: values[4] as? String, states: states, actions: actions,
                                        frame: AXAccess.frame(position: values[9] as CFTypeRef, size: values[10] as CFTypeRef))
        let children = values[11] as? [AXUIElement] ?? []
        for child in children {
            guard elements.count < maxNodes, ProcessInfo.processInfo.systemUptime < deadline else { truncated = true; break }
            if let captured = try visit(child, depth: depth + 1) { node.children.append(captured) }
        }
        return node
    }
}
