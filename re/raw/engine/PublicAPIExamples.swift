// Public-API replacement building blocks, NOT recovered product source.
// Type-check only: do not call without explicit user authorization/TCC grants.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreGraphics

struct EngineFailure: Error { let message: String }

func axValue(_ element: AXUIElement, _ key: CFString) throws -> CFTypeRef {
    var result: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(element, key, &result)
    guard status == .success, let result else {
        throw EngineFailure(message: "AX read failed: \(status.rawValue)")
    }
    return result
}
func setAXText(_ element: AXUIElement, text: String) throws {
    var writable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &writable) == .success,
          writable.boolValue else { throw EngineFailure(message: "AXValue not settable") }
    let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
    guard status == .success else { throw EngineFailure(message: "AX write failed: \(status.rawValue)") }
}
func setAXSelection(_ element: AXUIElement, utf16Range: NSRange) throws {
    var range = CFRange(location: utf16Range.location, length: utf16Range.length)
    guard let value = AXValueCreate(.cfRange, &range) else { throw EngineFailure(message: "range creation failed") }
    let status = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    guard status == .success else { throw EngineFailure(message: "selection failed: \(status.rawValue)") }
}
func axAction(_ element: AXUIElement, action: String) throws {
    let status = AXUIElementPerformAction(element, action as CFString)
    guard status == .success else { throw EngineFailure(message: "action failed: \(status.rawValue)") }
}
@available(macOS 14.0, *)
func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw EngineFailure(message: "window unavailable")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.showsCursor = false
    configuration.width = max(1, Int(window.frame.width * CGFloat(filter.pointPixelScale)))
    configuration.height = max(1, Int(window.frame.height * CGFloat(filter.pointPixelScale)))
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
}
func sendClick(pid: pid_t, globalPoint: CGPoint) throws {
    let source = CGEventSource(stateID: .privateState)
    guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                             mouseCursorPosition: globalPoint, mouseButton: .left),
          let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                           mouseCursorPosition: globalPoint, mouseButton: .left) else {
        throw EngineFailure(message: "event creation failed")
    }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    down.postToPid(pid)
    up.postToPid(pid)
}
func sendUnicode(pid: pid_t, text: String) throws {
    // Production code should chunk long strings at safe Unicode boundaries.
    let units = Array(text.utf16)
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        throw EngineFailure(message: "keyboard creation failed")
    }
    units.withUnsafeBufferPointer { buffer in
        if let base = buffer.baseAddress {
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }
    }
    down.postToPid(pid); up.postToPid(pid)
}
func sendScroll(pid: pid_t, at point: CGPoint, dx: Int32, dy: Int32) throws {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
        throw EngineFailure(message: "scroll creation failed")
    }
    event.location = point
    event.postToPid(pid)
}
@MainActor
func runningApps() -> [(name: String?, bundleID: String?, pid: pid_t, path: URL?)] {
    NSWorkspace.shared.runningApplications.map { ($0.localizedName, $0.bundleIdentifier, $0.processIdentifier, $0.bundleURL) }
}
func windowDescriptions() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}
