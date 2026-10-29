// Standalone: swiftc -parse-as-library scripts/cursor-probe.swift -o /tmp/cursor-probe
// sample | inspect [bundle] | run [bundle] [--allow-self-chat] | monitor [seconds]
// No CLI/SwiftCUA imports. run only writes a disposable TextEdit document or
// an explicitly confirmed knight self-chat. It never focuses/activates/warps.
import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreMedia

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
}
func sample(_ phase: String) {
    let p = CGEvent(source: nil)?.location
    let front = NSWorkspace.shared.frontmostApplication
    emit(["kind": "sample", "phase": phase, "time": Date().timeIntervalSince1970,
          "x": p?.x ?? Double.nan, "y": p?.y ?? Double.nan,
          "frontPID": front?.processIdentifier ?? -1, "frontmost": front?.bundleIdentifier ?? "unknown"])
}
func value(_ e: AXUIElement, _ key: String) -> CFTypeRef? {
    var out: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(e, key as CFString, &out)
    return out
}
func tree(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard depth < 35, result.count < 1500 else { return }
        result.append(e)
        for child in value(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(root, 0)
    return result
}
func text(_ e: AXUIElement, _ key: String) -> String { value(e, key) as? String ?? "" }
struct ProbeError: Error, CustomStringConvertible { let description: String }
final class Frames: NSObject, SCStreamOutput, @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        lock.lock(); count += 1; lock.unlock()
    }
    func total() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct CursorProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { emit(["kind": "error", "message": String(describing: error)]); exit(1) }
    }
    @MainActor static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let mode = args.first ?? "sample"
        if mode == "sample" { sample("sample"); return }
        emit(["kind": "identity", "probePID": getpid(), "accessibility": AXIsProcessTrusted(),
              "screenRecording": CGPreflightScreenCaptureAccess()])
        guard AXIsProcessTrusted() else { throw ProbeError(description: "Accessibility missing for probe host; no prompts requested") }
        let mask = [CGEventType.mouseMoved, .leftMouseDown, .leftMouseDragged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, _ in
            emit(["kind": "event", "time": Date().timeIntervalSince1970, "type": type.rawValue,
                  "sourcePID": event.getIntegerValueField(.eventSourceUnixProcessID),
                  "sourceState": event.getIntegerValueField(.eventSourceStateID),
                  "x": event.location.x, "y": event.location.y])
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else { throw ProbeError(description: "CGEventTap denied (Input Monitoring/Accessibility); attribution unavailable") }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        defer { CGEvent.tapEnable(tap: tap, enable: false); CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if mode == "monitor" {
            let duration = min(120, max(1, Double(args.dropFirst().first ?? "10") ?? 10))
            sample("monitor-before")
            for _ in 0..<Int(duration * 20) { try await Task.sleep(for: .milliseconds(50)); sample("monitor") }
            return
        }
        let bundle = args.count > 1 ? args[1] : "com.apple.TextEdit"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { throw ProbeError(description: "Target is not running: \(bundle)") }
        emit(["kind": "target", "bundle": bundle, "targetPID": app.processIdentifier])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        let nodes = tree(root)
        if mode == "inspect" {
            for (i, e) in nodes.enumerated() {
                let role = text(e, kAXRoleAttribute)
                if ["AXWindow", "AXTextArea", "AXTextField", "AXButton", "AXStaticText"].contains(role) {
                    var settable: DarwinBoolean = false
                    _ = AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
                    emit(["kind": "ax", "index": i, "role": role, "title": text(e, kAXTitleAttribute),
                          "description": text(e, kAXDescriptionAttribute), "valueSettable": settable.boolValue,
                          "valueUTF16Length": text(e, kAXValueAttribute).utf16.count,
                          "whitespaceOnly": text(e, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty])
                }
            }
            sample("inspect-after"); return
        }
        guard mode == "run" else { throw ProbeError(description: "Unknown mode") }
        let windows = value(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let window: AXUIElement
        if bundle == "com.apple.TextEdit", let safe = windows.first(where: { text($0, kAXTitleAttribute).hasPrefix("SwiftCUA-Cursor-Test") }) {
            window = safe
        } else if bundle == "com.tencent.xinWeChat", args.contains("--allow-self-chat"), windows.count > 0 {
            window = windows[0]
            // Require exact chat heading, never substring-match a group name/message.
            let headings = tree(window).filter { text($0, kAXRoleAttribute) == "AXTextArea" && text($0, kAXTitleAttribute) == "knight" }
            guard !headings.isEmpty else { throw ProbeError(description: "Cannot verify knight heading; refusing write/send") }
        } else { throw ProbeError(description: "Safety gate: use a TextEdit document titled SwiftCUA-Cursor-Test… or explicitly confirmed knight self-chat") }
        guard let input = tree(window).first(where: { text($0, kAXRoleAttribute) == "AXTextArea" }) else { throw ProbeError(description: "No AXTextArea; refusing fallback input") }
        if bundle == "com.tencent.xinWeChat", text(input, kAXTitleAttribute) != "knight" {
            throw ProbeError(description: "Selected input is not knight; refusing write/send")
        }
        let original = text(input, kAXValueAttribute)
        if bundle != "com.apple.TextEdit", !original.isEmpty { throw ProbeError(description: "Chat draft is nonempty; refusing to overwrite") }
        // Always restore TextEdit and clear an unsent test draft on failure.
        defer { _ = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, original as CFString) }
        sample("baseline-before")
        try await Task.sleep(for: .seconds(1)); sample("baseline-after")
        sample("ax-write-before")
        let marker = "SwiftCUA cursor probe \(ISO8601DateFormatter().string(from: Date()))"
        let result = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, marker as CFString)
        emit(["kind": "api", "name": "AXUIElementSetAttributeValue", "result": result.rawValue])
        guard result == .success else { throw ProbeError(description: "AX write rejected; no keyboard fallback") }
        try await Task.sleep(for: .seconds(1)); sample("ax-write-after")
        sample("pid-return-before")
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down) else { throw ProbeError(description: "Cannot create Return") }
            event.postToPid(app.processIdentifier)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(1)); sample("pid-return-after")
        sample("scstream-before")
        guard CGPreflightScreenCaptureAccess() else { throw ProbeError(description: "Screen Recording missing; stream step not tested") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var axOrigin = CGPoint.zero, axSize = CGSize.zero
        if let raw = value(window, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            _ = AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgPoint, &axOrigin)
        }
        if let raw = value(window, kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            _ = AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cgSize, &axSize)
        }
        guard let target = content.windows.first(where: {
            $0.owningApplication?.processID == app.processIdentifier &&
            abs($0.frame.minX - axOrigin.x) < 3 && abs($0.frame.minY - axOrigin.y) < 3 &&
            abs($0.frame.width - axSize.width) < 3 && abs($0.frame.height - axSize.height) < 3
        }) else { throw ProbeError(description: "No SCWindow matching the AX target geometry; refusing helper-window capture") }
        let config = SCStreamConfiguration()
        config.width = 480; config.height = 480; config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config, delegate: nil)
        let output = Frames()
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cursor.probe.frames"))
        try await stream.startCapture()
        try await Task.sleep(for: .seconds(2))
        try await stream.stopCapture()
        emit(["kind": "api", "name": "SCStream", "frames": output.total(), "windowID": target.windowID])
        sample("scstream-after")
        sample("ax-read-before")
        emit(["kind": "api", "name": "AX-read", "nodes": tree(root).count])
        try await Task.sleep(for: .seconds(1)); sample("ax-read-after")
        emit(["kind": "note", "message": "PID=0 is unattributed/hardware, not proof of user input. Location change without a matching tap event is only warp-compatible, not proof of which process warped. Compare baseline and isolated steps; never restore physical cursor." ])
    }
}
