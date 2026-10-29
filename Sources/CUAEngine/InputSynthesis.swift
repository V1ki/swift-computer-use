import Foundation
import AppKit
import ApplicationServices
import CUACore

/// 仅从 SkyEngine 的非 MainActor 隔离上下文调用；一次手势保持串行，避免按键交错。
enum InputSynthesis {
    static func pause(_ milliseconds: Int) { Thread.sleep(forTimeInterval: Double(max(0, min(milliseconds, 10_000))) / 1000) }
    static func duration(_ milliseconds: Int?) throws -> Int {
        let value = milliseconds ?? 20
        guard (0...10_000).contains(value) else { throw CUAError.invalidParams("durationMilliseconds must be 0...10000", method: "input") }
        return value
    }
    static func post(_ event: CGEvent?) throws {
        guard let event else { throw CUAError(code: .inputRejected, message: "Cannot allocate input event") }
        event.post(tap: .cghidEventTap)
    }
    static func key(_ chord: KeyChord, duration: Int = 20) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.keyCode, keyDown: false) else {
            throw CUAError(code: .inputRejected, message: "Cannot allocate keyboard events")
        }
        down.flags = chord.flags; up.flags = chord.flags
        if let text = chord.unicode {
            let units = Array(text.utf16)
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        down.post(tap: .cghidEventTap)
        pause(duration)
        up.post(tap: .cghidEventTap)
    }
    static func text(_ text: String) throws {
        for units in TextInput.chunks(text) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw CUAError(code: .inputRejected, message: "Cannot allocate Unicode events")
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            pause(5)
        }
    }
    static func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, flags: CGEventFlags = [], count: Int = 1) throws {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.flags = flags
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        try post(event)
    }
    static func click(at point: CGPoint, button: CUAMouseButton, count: Int, flags: CGEventFlags, duration: Int) throws {
        guard (1...10).contains(count) else { throw CUAError.invalidParams("clickCount must be 1...10", method: "click") }
        let cgButton: CGMouseButton = button == .left ? .left : button == .right ? .right : .center
        let down: CGEventType = button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown
        let up: CGEventType = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
        for i in 1...count {
            try mouse(down, at: point, button: cgButton, flags: flags, count: i)
            pause(duration)
            try mouse(up, at: point, button: cgButton, flags: flags, count: i)
            if i < count { pause(60) }
        }
    }
    static func paste(_ text: String, format: CUAPasteFormat) throws {
        let board = NSPasteboard.general
        // 保留每个 item 的所有具体数据类型；不持有已被 clearContents 失效的 lazy provider。
        let saved = (board.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { values[type] = data } }
            return values
        }
        board.clearContents()
        board.setString(text, forType: .string)
        if format == .html { board.setString(text, forType: .html) }
        if format == .md { board.setString(text, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown")) }
        let writtenVersion = board.changeCount
        defer {
            // 用户/其他程序同时写入剪贴板时不覆盖新内容。
            if board.changeCount == writtenVersion {
                board.clearContents()
                let items = saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { board.writeObjects(items) }
            }
        }
        try key(KeyChord.parse("Cmd+v"))
        pause(250)
    }
}
