import AppKit
import ApplicationServices
import CUACore

extension AXAccess {
    static func attributes(_ element: AXUIElement) throws -> [String] {
        var names: CFArray?
        try check(AXUIElementCopyAttributeNames(element, &names), context: "List attributes")
        return (names as? [String] ?? []).sorted()
    }
    /// Bounded, typed conversion. AX references are described, never recursively traversed.
    static func json(_ raw: CFTypeRef, depth: Int = 0) -> JSONValue {
        guard depth < 4 else { return .object(["unavailable": "depth-limit"]) }
        if CFGetTypeID(raw) == CFBooleanGetTypeID() { return .bool((raw as? Bool) == true) }
        if let value = raw as? String { return .string(String(value.prefix(16_384))) }
        if let value = raw as? NSNumber { return .double(value.doubleValue) }
        if let element = element(raw) {
            return .object(["role": value(element, kAXRoleAttribute).map { json($0, depth: depth + 1) } ?? .null,
                            "title": value(element, kAXTitleAttribute).map { json($0, depth: depth + 1) } ?? .null])
        }
        if CFGetTypeID(raw) == AXValueGetTypeID() {
            let value = unsafeDowncast(raw, to: AXValue.self)
            switch AXValueGetType(value) {
            case .cgPoint:
                var point = CGPoint.zero
                if AXValueGetValue(value, .cgPoint, &point) { return .object(["x": .double(point.x), "y": .double(point.y)]) }
            case .cgSize:
                var size = CGSize.zero
                if AXValueGetValue(value, .cgSize, &size) { return .object(["width": .double(size.width), "height": .double(size.height)]) }
            case .cfRange:
                var range = CFRange()
                if AXValueGetValue(value, .cfRange, &range) { return .object(["location": .int(range.location), "length": .int(range.length)]) }
            default: break
            }
        }
        if let values = raw as? [Any] { return .array(values.prefix(200).map { json($0 as CFTypeRef, depth: depth + 1) }) }
        return .object(["unavailable": "unsupported-type"])
    }
    static func writable(_ value: JSONValue) throws -> CFTypeRef {
        switch value {
        case .string(let value): return value as CFString
        case .bool(let value): return value ? kCFBooleanTrue : kCFBooleanFalse
        case .int(let value): return NSNumber(value: value)
        case .double(let value) where value.isFinite: return NSNumber(value: value)
        case .object(let value):
            if let x = value["x"]?.doubleValue, let y = value["y"]?.doubleValue, x.isFinite, y.isFinite, value.count == 2 {
                var point = CGPoint(x: x, y: y)
                if let result = AXValueCreate(.cgPoint, &point) { return result }
            }
            if let w = value["width"]?.doubleValue, let h = value["height"]?.doubleValue, w.isFinite, h.isFinite, w >= 0, h >= 0, value.count == 2 {
                var size = CGSize(width: w, height: h)
                if let result = AXValueCreate(.cgSize, &size) { return result }
            }
            if case .int(let location) = value["location"], case .int(let length) = value["length"], location >= 0, length >= 0, location <= Int.max - length, value.count == 2 {
                var range = CFRange(location: location, length: length)
                if let result = AXValueCreate(.cfRange, &range) { return result }
            }
            fallthrough
        default: throw CUAError.invalidParams("AX value supports string, bool, finite number, point, size, or nonnegative UTF-16 range", method: "axSet")
        }
    }
}

extension SkyEngine {
    func desktopInfo() -> JSONValue {
        let front = NSWorkspace.shared.frontmostApplication
        let cursor = CGEvent(source: nil)?.location
        return .object(["frontmostApp": front.map { .string(AppCatalog.identifier($0)) } ?? .null,
                        "frontmostPID": front.map { .int(Int($0.processIdentifier)) } ?? .null,
                        "cursor": cursor.map { .object(["x": .double($0.x), "y": .double($0.y)]) } ?? .null])
    }
    func inspectionInfo(_ app: NSRunningApplication, window: CUAWindowInfo?) -> JSONValue {
        var info = desktopInfo().objectValue ?? [:]
        info["pid"] = .int(Int(app.processIdentifier))
        info["bundleIdentifier"] = app.bundleIdentifier.map(JSONValue.string) ?? .null
        info["name"] = app.localizedName.map(JSONValue.string) ?? .null
        info["activationPolicy"] = .string(app.activationPolicy == .regular ? "regular" : app.activationPolicy == .accessory ? "accessory" : "prohibited")
        info["isActive"] = .bool(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)
        info["window"] = window.flatMap { try? CUACodec.jsonValue($0) } ?? .null
        info["permissions"] = .object(["accessibility": .bool(AXIsProcessTrusted()), "screenRecording": .bool(CGPreflightScreenCaptureAccess())])
        return .object(info)
    }
    func observe(_ app: String, index: Int?) -> JSONValue {
        guard let running = try? AppCatalog.running(app) else { return .null }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
        let element = index.flatMap { try? resolve(running, index: $0, windowID: nil) }
            ?? AXAccess.element(AXAccess.value(axApp, kAXFocusedUIElementAttribute))
        var values: [String: JSONValue] = [:]
        if let element {
            for name in [kAXRoleAttribute, kAXTitleAttribute, kAXValueAttribute, kAXFocusedAttribute, kAXSelectedAttribute, kAXExpandedAttribute, kAXSelectedTextRangeAttribute, kAXPositionAttribute, kAXSizeAttribute] {
                if let value = AXAccess.value(element, name) { values[name] = AXAccess.json(value) }
            }
        }
        return .object(["element": .object(values), "windows": (try? CUACodec.jsonValue(AppCatalog.windows().filter { $0.app == AppCatalog.identifier(running) })) ?? .null])
    }
    func result(before: JSONValue, desktop: JSONValue, app: String, index: Int?, path: String) -> CUAActionResult {
        // A short bounded settle, never retry a mutation automatically.
        InputSynthesis.pause(60)
        let after = observe(app, index: index)
        return CUAActionResult(changed: before == .null || after == .null ? nil : AXPrimitive.changed(before: before, after: after), path: path,
                               evidence: .object(["before": before, "after": after, "desktopBefore": desktop, "desktopAfter": desktopInfo(), "scope": "target attributes and window metadata; not proof of intended outcome"]))
    }
    public func ax(_ method: CUAMethod, params: AXParams) async throws -> JSONValue {
        let trace = CursorTrace(action: method.rawValue, allowActivation: actionActivation)
        return try InputSynthesis.$context.withValue(InputContext(allowActivation: actionActivation, trace: trace)) {
            trace.record("before")
            defer { trace.record("after") }
            try AXAccess.checkPermission()
            let app = try AppCatalog.running(params.app)
            let element = try resolve(app, index: params.elementIndex, windowID: params.windowId)
            switch method {
            case .axAttributes:
                let names = try AXAccess.attributes(element)
                return .object(["attributes": .array(names.map { name in
                    var settable = DarwinBoolean(false)
                    let status = AXUIElementIsAttributeSettable(element, name as CFString, &settable)
                    return .object(["name": .string(name), "settable": status == .success ? .bool(settable.boolValue) : .null])
                })])
            case .axActions: return .object(["actions": .array(AXAccess.actions(element).sorted().map(JSONValue.string))])
            case .axGet:
                let name = try AXPrimitive.name(params.attribute, available: AXAccess.attributes(element))
                var raw: CFTypeRef?
                try AXAccess.check(AXUIElementCopyAttributeValue(element, name as CFString, &raw), context: "Read \(name)")
                return .object(["attribute": .string(name), "value": raw.map { AXAccess.json($0) } ?? .null])
            case .axSet, .axFocus, .axAction:
                let desktop = desktopInfo()
                let before = observe(params.app, index: params.elementIndex)
                let name: String
                if method == .axAction {
                    name = try AXPrimitive.name(params.action, available: AXAccess.actions(element))
                    try AXPrimitive.checkMutation(name, activate: allowActivation)
                    try AXAccess.check(AXUIElementPerformAction(element, name as CFString), context: name)
                } else {
                    name = try AXPrimitive.name(method == .axFocus ? kAXFocusedAttribute : params.attribute, available: AXAccess.attributes(element))
                    try AXPrimitive.checkMutation(name, activate: allowActivation)
                    var settable = DarwinBoolean(false)
                    try AXAccess.check(AXUIElementIsAttributeSettable(element, name as CFString, &settable), context: "Check writable \(name)")
                    guard settable.boolValue else { throw CUAError(code: .unsupported, message: "\(name) is read-only") }
                    guard let value = method == .axFocus ? JSONValue.bool(true) : params.value else { throw CUAError.invalidParams("Missing value", method: "axSet") }
                    let encoded = try AXAccess.writable(value)
                    let previous = AXAccess.value(element, name).map { AXAccess.json($0) }
                    try AXAccess.check(AXUIElementSetAttributeValue(element, name as CFString, encoded), context: "Write \(name)")
                    InputSynthesis.pause(60)
                    let after = AXAccess.value(element, name).map { AXAccess.json($0) }
                    return try CUACodec.jsonValue(CUAActionResult(changed: AXPrimitive.changed(before: previous, after: after), path: "ax-set:\(name)", evidence: .object(["before": previous ?? .null, "after": after ?? .null, "requested": value, "matchesRequested": .bool(after == AXAccess.json(encoded)), "desktopBefore": desktop, "desktopAfter": desktopInfo()])))
                }
                return try CUACodec.jsonValue(result(before: before, desktop: desktop, app: params.app, index: params.elementIndex, path: "ax-action:\(name)"))
            default: throw CUAError.invalidParams("Not an AX primitive", method: method.rawValue)
            }
        }
    }
}
