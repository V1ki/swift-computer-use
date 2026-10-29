import Foundation
import CoreGraphics
import CUACore

/// 纯函数：所有输入坐标均为左上角原点的 points，不按 Retina 比例重复缩放。
enum Coordinates {
    static func global(_ point: CUAPoint, in window: CUARect) -> CGPoint {
        CGPoint(x: window.x + point.x, y: window.y + point.y)
    }
    static func center(_ rect: CUARect) -> CGPoint {
        CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
    }
    static func pixels(_ rect: CUARect, scale: Double) -> (Int, Int) {
        (max(1, Int(ceil(rect.width * scale))), max(1, Int(ceil(rect.height * scale))))
    }
}

/// 索引只对最近一次抓取有效；PID、窗口或时间变化均不能误用旧引用。
struct IndexStamp {
    let pid: Int32
    let windowID: UInt32?
    let capturedAt: Date
    func validate(pid: Int32, windowID: UInt32?, now: Date = Date(), maxAge: TimeInterval = 120) throws {
        guard self.pid == pid, windowID == nil || windowID == self.windowID,
              now.timeIntervalSince(capturedAt) >= 0, now.timeIntervalSince(capturedAt) <= maxAge else {
            throw CUAError(code: .elementIndexStale, message: "Accessibility indices expired; call getAppState again")
        }
    }
    static func requireIndex<T>(_ index: Int, in table: [Int: T]) throws -> T {
        guard let value = table[index] else { throw CUAError(code: .elementNotFound, message: "Unknown element index \(index)") }
        return value
    }
}

public enum AXFormat {
    /// Presentation-only bounds: never renumber or replace the captured index table.
    public static func bounded(_ nodes: [CUAAccessibilityNode], limit: Int, depth: Int) -> (nodes: [CUAAccessibilityNode], truncated: Bool) {
        var remaining = limit
        var truncated = false
        func visit(_ nodes: [CUAAccessibilityNode], level: Int) -> [CUAAccessibilityNode] {
            nodes.compactMap { node in
                guard remaining > 0, level <= depth else { truncated = true; return nil }
                remaining -= 1
                var copy = node
                copy.children = visit(node.children, level: level + 1)
                return copy
            }
        }
        let result = visit(nodes, level: 0)
        return (result, truncated)
    }

    public static func filter(_ nodes: [CUAAccessibilityNode], query: String?) -> [CUAAccessibilityNode] {
        guard let query, !query.isEmpty else { return nodes }
        return nodes.compactMap { node in
            var copy = node
            copy.children = filter(node.children, query: query)
            let fields = [node.role, node.subrole, node.title, node.value, node.description, node.identifier].compactMap { $0 }
            return !copy.children.isEmpty || fields.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ? copy : nil
        }
    }
    public static func render(_ nodes: [CUAAccessibilityNode], windowTitle: String? = nil, truncated: Bool = false) -> String {
        var lines: [String] = []
        func quote(_ value: String, limit: Int = 80) -> String {
            let clipped = String(value.prefix(limit)) + (value.count > limit ? "…" : "")
            return "\"" + clipped.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
        }
        func visit(_ node: CUAAccessibilityNode, depth: Int) {
            guard !node.states.contains("hidden"), !node.states.contains("invalid"), !node.role.isEmpty else { return }
            let role = node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)) : node.role
            var line = String(repeating: "  ", count: depth) + "[\(node.index)] \(role.prefix(1).lowercased() + role.dropFirst())"
            if let subrole = node.subrole { line += " subrole=" + quote(subrole) }
            if let identifier = node.identifier { line += " identifier=" + quote(identifier) }
            if let title = node.title, !title.isEmpty { line += " " + quote(title) }
            if let value = node.value, !value.isEmpty { line += " value=" + quote(value) }
            if let description = node.description, !description.isEmpty, description != node.title { line += " description=" + quote(description) }
            if !node.states.isEmpty { line += " {" + node.states.joined(separator: ", ") + "}" }
            if !node.actions.isEmpty { line += " actions=[" + node.actions.joined(separator: ", ") + "]" }
            if let r = node.frame { line += " frame=(\(number(r.x)),\(number(r.y)),\(number(r.width)),\(number(r.height)))" }
            lines.append(line)
            node.children.forEach { visit($0, depth: depth + 1) }
        }
        nodes.forEach { visit($0, depth: 0) }
        return (["Window: \(quote(windowTitle ?? "Untitled")); elements=\(lines.count); truncated=\(truncated)"] + lines).joined(separator: "\n")
    }
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "?" }
        return String(format: "%.1f", value)
    }
}

struct KeyChord {
    var keyCode: CGKeyCode
    var flags: CGEventFlags
    var unicode: String?

    static func modifier(_ raw: String) -> CGEventFlags? {
        switch raw.lowercased() {
        case "control_l", "control_r", "control", "ctrl": return .maskControl
        case "shift_l", "shift_r", "shift": return .maskShift
        case "alt_l", "alt_r", "alt", "option": return .maskAlternate
        case "super_l", "super_r", "meta_l", "meta_r", "cmd", "command", "meta", "super": return .maskCommand
        default: return nil
        }
    }
    static func parse(_ raw: String) throws -> KeyChord {
        let normalized = raw == "+" ? "plus" : raw.hasSuffix("++") ? String(raw.dropLast()) + "plus" : raw
        let parts = normalized.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { throw invalid(raw) }
        var flags: CGEventFlags = []
        for part in parts.dropLast() {
            guard let flag = modifier(part) else { throw invalid(raw) }
            flags.formUnion(flag)
        }
        let key = parts.last!
        let lower = key.lowercased()
        if let flag = modifier(key) {
            let code: CGKeyCode = flag == .maskControl ? 59 : flag == .maskShift ? 56 : flag == .maskAlternate ? 58 : 55
            flags.formUnion(flag)
            return KeyChord(keyCode: code, flags: flags, unicode: nil)
        }
        if let code = shiftedCodes[lower] {
            flags.insert(.maskShift)
            return KeyChord(keyCode: code, flags: flags, unicode: nil)
        }
        if let code = codes[lower] {
            if key.count == 1, key != lower { flags.insert(.maskShift) }
            return KeyChord(keyCode: code, flags: flags, unicode: nil)
        }
        if key.count == 1, let scalar = key.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
            if key != lower { flags.insert(.maskShift) }
            return KeyChord(keyCode: codes[lower] ?? 0, flags: flags, unicode: codes[lower] == nil ? key : nil)
        }
        throw invalid(raw)
    }
    private static func invalid(_ key: String) -> CUAError { .invalidParams("Invalid key chord: \(key)", method: "pressKey") }
    static let shiftedCodes: [String: CGKeyCode] = [
        "!":18,"exclam":18,"@":19,"at":19,"#":20,"numbersign":20,"$":21,"dollar":21,
        "%":23,"percent":23,"^":22,"asciicircum":22,"&":26,"ampersand":26,"*":28,"asterisk":28,
        "(":25,"parenleft":25,")":29,"parenright":29,"_":27,"underscore":27,"plus":24,
        "{":33,"braceleft":33,"}":30,"braceright":30,"|":42,"bar":42,":":41,"colon":41,
        "\"":39,"quotedbl":39,"<":43,"less":43,">":47,"greater":47,"?":44,"question":44,"~":50,"asciitilde":50
    ]
    static let codes: [String: CGKeyCode] = {
        var result: [String: CGKeyCode] = [
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,
            "q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,
            "=":24,"equal":24,"9":25,"7":26,"-":27,"minus":27,"8":28,"0":29,
            "]":30,"bracketright":30,"o":31,"u":32,"[":33,"bracketleft":33,"i":34,"p":35,
            "return":36,"enter":36,"l":37,"j":38,"'":39,"apostrophe":39,"k":40,";":41,"semicolon":41,
            "\\":42,"backslash":42,",":43,"comma":43,"/":44,"slash":44,"n":45,"m":46,".":47,"period":47,
            "tab":48,"space":49," ":49,"`":50,"grave":50,"backspace":51,"escape":53,"esc":53,
            "delete":117,"forwarddelete":117,"home":115,"end":119,"page_up":116,"pageup":116,"page_down":121,"pagedown":121,
            "left":123,"right":124,"down":125,"up":126,
            "kp_space":49,"kp_tab":48,"kp_home":115,"kp_end":119,"kp_left":123,"kp_right":124,"kp_down":125,"kp_up":126,
            "kp_prior":116,"kp_page_up":116,"kp_next":121,"kp_page_down":121,"kp_delete":117,"kp_begin":71,
            "kp_decimal":65,"kp_multiply":67,"kp_add":69,"kp_divide":75,"kp_enter":76,"kp_subtract":78,"kp_equal":81,
            "kp_0":82,"kp_1":83,"kp_2":84,"kp_3":85,"kp_4":86,"kp_5":87,"kp_6":88,"kp_7":89,"kp_8":91,"kp_9":92
        ]
        let f: [CGKeyCode] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        for (i, code) in f.enumerated() { result["f\(i + 1)"] = code }
        return result
    }()
}

enum TextInput {
    /// 按 Unicode scalar 分段，绝不切断 UTF-16 代理对。
    static func chunks(_ text: String, limit: Int = 20) -> [[UInt16]] {
        var result: [[UInt16]] = [], chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > max(2, limit) { result.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
    static func selection(in source: String, text: String, prefix: String?, suffix: String?, type: CUASelectionType) throws -> CFRange {
        let ns = source as NSString
        let needle = (prefix ?? "") + text + (suffix ?? "")
        let range = ns.range(of: needle)
        guard range.location != NSNotFound else { throw CUAError(code: .elementNotFound, message: "Selection text not found") }
        let start = range.location + (prefix ?? "").utf16.count
        switch type {
        case .text: return CFRange(location: start, length: text.utf16.count)
        case .cursorBefore: return CFRange(location: start, length: 0)
        case .cursorAfter: return CFRange(location: start + text.utf16.count, length: 0)
        }
    }
}

/// Pure text-matching helpers shared by AX lookup and OCR fallback.
enum TextMatch {
    static func matches(_ haystack: String, query: String, exact: Bool) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        let hay = haystack.trimmingCharacters(in: .whitespacesAndNewlines)
        return exact ? hay.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                     : hay.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Walks the AX tree and returns every node whose visible text contains the query.
    /// Rects are converted from global to window-relative coordinates.
    static func tree(_ nodes: [CUAAccessibilityNode], query: String, exact: Bool,
                     windowOrigin: CUARect?, windowId: UInt32? = nil) -> [CUATextMatch] {
        var out: [CUATextMatch] = []
        func visit(_ node: CUAAccessibilityNode) {
            let text = [node.title, node.value, node.description]
                .compactMap { $0 }
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if let text, let frame = node.frame, matches(text, query: query, exact: exact) {
                var rect = frame
                if let windowOrigin {
                    rect = CUARect(x: frame.x - windowOrigin.x, y: frame.y - windowOrigin.y,
                                   width: frame.width, height: frame.height)
                }
                out.append(CUATextMatch(index: node.index, text: text, role: node.role, rect: rect,
                                       source: "ax", windowId: windowId))
            }
            node.children.forEach(visit)
        }
        nodes.forEach(visit)
        return out
    }

    /// Prefer an AX hit with a usable frame; among equals prefer the smallest area
    /// (leaf labels beat their container groups) and OCR confidence as tiebreak.
    static func pick(_ matches: [CUATextMatch]) -> CUATextMatch? {
        let usable = matches.filter { $0.rect.width > 0 && $0.rect.height > 0 }
        guard !usable.isEmpty else { return matches.first }
        return usable.min { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source == "ax" }
            let lhsArea = lhs.rect.width * lhs.rect.height
            let rhsArea = rhs.rect.width * rhs.rect.height
            if abs(lhsArea - rhsArea) > 1 { return lhsArea < rhsArea }
            return (lhs.confidence ?? 0) > (rhs.confidence ?? 0)
        }
    }
}
