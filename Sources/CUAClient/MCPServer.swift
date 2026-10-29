import Foundation
import CUACore

struct MCPTool: Sendable {
    let name: String
    let method: CUAMethod
    let description: String
    let properties: [String: JSONValue]
    let required: [String]

    var json: JSONValue {
        .object(["name": .string(name), "description": .string(description), "inputSchema": .object([
            "type": "object", "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)), "additionalProperties": false
        ])])
    }

    /// 基础模式验证提前阻止拼写错误；更复杂的目标语义交给服务端验证。
    func validate(_ arguments: JSONValue) throws {
        guard let object = arguments.objectValue else { throw invalid("arguments must be an object") }
        for field in required where object[field] == nil { throw invalid("Missing required field: \(field)") }
        for (field, value) in object {
            guard let schema = properties[field] else { throw invalid("Unknown field: \(field)") }
            if value == .null && !required.contains(field) { continue }
            let valid: Bool
            switch schema["type"]?.stringValue {
            case "string": valid = value.stringValue != nil
            case "boolean": valid = value.boolValue != nil
            case "integer": if case .int = value { valid = true } else { valid = false }
            case "number": valid = value.doubleValue?.isFinite == true
            default: valid = false
            }
            guard valid else { throw invalid("Invalid type for \(field)") }
            if let values = schema["enum"]?.arrayValue, !values.contains(value) { throw invalid("Invalid value for \(field)") }
            if let minimum = schema["minimum"]?.doubleValue, let number = value.doubleValue, number < minimum {
                throw invalid("\(field) must be >= \(minimum)")
            }
            if let maximum = schema["maximum"]?.doubleValue, let number = value.doubleValue, number > maximum {
                throw invalid("\(field) must be <= \(maximum)")
            }
        }
    }

    private func invalid(_ message: String) -> ClientError { ClientError(code: -32602, message: message) }
}

enum MCPTools {
    private static func field(_ type: String, _ description: String, values: [String]? = nil,
                              minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }
    private static let app = field("string", "Application bundle identifier or process path")
    private static let session = field("string", "Authorized service session identifier")
    private static let window = field("integer", "CGWindowID of target window", minimum: 0, maximum: Double(UInt32.max))
    private static let element = field("integer", "Element index from the latest get_app_state", minimum: 0)
    private static let coordinate = field("number", "Window-relative coordinate in points")
    private static let duration = field("integer", "Hold duration in milliseconds", minimum: 0)
    private static let text = field("string", "Text content")
    private static let key = field("string", "Key chord, for example Control_L+a")

    private static func tool(_ name: String, _ method: CUAMethod, _ description: String,
                             _ extra: [String: JSONValue] = [:], required: [String] = [], target: Bool = false) -> MCPTool {
        var properties = extra
        if target { properties.merge(["app": app, "sessionId": session, "windowId": window]) { current, _ in current } }
        return MCPTool(name: name, method: method, description: description, properties: properties, required: required)
    }

    static let all: [MCPTool] = [
        tool("list_apps", .listApps, "List installed and running applications", [
            "includeWindows": field("boolean", "Include each app's windows"), "sessionId": session]),
        tool("list_windows", .listWindows, "List mapped application windows"),
        tool("get_app_state", .getAppState, "Get accessibility tree and optional screenshot; refreshes element indices", [
            "includeScreenshot": field("boolean", "Capture screenshot, default true"),
            "includeText": field("boolean", "Capture accessibility text, default true"),
            "disableDiff": field("boolean", "Return full tree instead of a diff"),
            "query": field("string", "Case-insensitive accessibility tree filter")], required: ["app"], target: true),
        tool("click", .click, "Click an element or window-relative x/y coordinates", [
            "elementIndex": element, "x": coordinate, "y": coordinate,
            "clickCount": field("integer", "Number of clicks", minimum: 1),
            "mouseButton": field("string", "Mouse button", values: ["left", "right", "middle", "l", "r", "m"]),
            "key": key, "durationMilliseconds": duration], required: ["app"], target: true),
        tool("press_key", .pressKey, "Press a key chord", ["key": key, "durationMilliseconds": duration], required: ["app", "key"], target: true),
        tool("type_text", .typeText, "Type text, optionally into an indexed element", ["text": text, "elementIndex": element], required: ["app", "text"], target: true),
        tool("scroll", .scroll, "Scroll an app or element", [
            "direction": field("string", "Scroll direction", values: ["up", "down", "left", "right", "u", "d", "l", "r"]),
            "elementIndex": element, "x": coordinate, "y": coordinate,
            "pages": field("number", "Number of pages"), "pixels": field("number", "Distance in pixels"),
            "scrollX": field("number", "Raw horizontal delta; negative is left"),
            "scrollY": field("number", "Raw vertical delta; negative is up")], required: ["app"], target: true),
        tool("set_value", .setValue, "Set accessibility element value", ["elementIndex": element, "value": text], required: ["app", "elementIndex", "value"], target: true),
        tool("drag", .drag, "Drag between window-relative coordinates", ["fromX": coordinate, "fromY": coordinate, "toX": coordinate, "toY": coordinate], required: ["app", "fromX", "fromY", "toX", "toY"], target: true),
        tool("paste", .paste, "Paste text via the clipboard", ["text": text, "format": field("string", "Clipboard format", values: ["text", "md", "html"])], required: ["app", "text"], target: true),
        tool("select_text", .selectText, "Select matching text or position the cursor", [
            "elementIndex": element, "text": text, "prefix": text, "suffix": text,
            "selectionType": field("string", "Selection behavior", values: ["text", "cursor_before", "cursor_after"])], required: ["app", "elementIndex", "text"], target: true),
        tool("perform_secondary_action", .performSecondaryAction, "Perform a named accessibility action", ["elementIndex": element, "action": field("string", "Action name from accessibility tree")], required: ["app", "elementIndex", "action"], target: true),
        tool("capture_screenshot", .captureScreenshot, "Capture an app, window, or display as data URLs", [
            "app": app, "sessionId": session, "windowId": window,
            "displayId": field("integer", "CGDirectDisplayID", minimum: 0, maximum: Double(UInt32.max))]),
        tool("get_permissions", .getPermissions, "Check Screen Recording and Accessibility permissions without prompting")
    ]
}

/// MCP 使用逐行 JSON，与 socket 的长度前缀帧严格分离；stdout 不输出日志。
struct MCPServer: Sendable {
    let client: SocketClient
    static let protocolVersion = "2025-06-18"
    static let supportedVersions = ["2024-11-05", "2025-03-26", protocolVersion]

    func handle(_ request: JSONValue) async -> JSONValue? {
        guard let object = request.objectValue, object["jsonrpc"] == .string("2.0"),
              let method = object["method"]?.stringValue else {
            return failure(id: request["id"] ?? .null, code: -32600, message: "Invalid JSON-RPC request")
        }
        guard let id = object["id"] else { return nil }
        guard id.stringValue != nil || { if case .int = id { return true }; return false }() else {
            return failure(id: .null, code: -32600, message: "Request id must be a string or integer")
        }
        let params = object["params"] ?? .object([:])
        guard params.objectValue != nil else { return failure(id: id, code: -32602, message: "params must be an object") }
        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"]?.stringValue,
                  params["capabilities"]?.objectValue != nil,
                  params["clientInfo"]?["name"]?.stringValue != nil,
                  params["clientInfo"]?["version"]?.stringValue != nil else {
                return failure(id: id, code: -32602, message: "initialize requires protocolVersion, capabilities and clientInfo {name, version}")
            }
            return success(id: id, result: .object([
                "protocolVersion": .string(Self.supportedVersions.contains(requested) ? requested : Self.protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": false])]),
                "serverInfo": .object(["name": "swiftcua", "version": .string(CUAProtocolVersion.serviceVersion)]),
                "instructions": "Use get_app_state to obtain fresh element indices before element-targeted actions."
            ]))
        case "ping": return success(id: id, result: .object([:]))
        case "tools/list": return success(id: id, result: .object(["tools": .array(MCPTools.all.map(\.json))]))
        case "tools/call":
            guard let name = params["name"]?.stringValue,
                  let tool = MCPTools.all.first(where: { $0.name == name }) else {
                return failure(id: id, code: -32602, message: "Unknown or missing tool name")
            }
            do {
                let arguments = params["arguments"] ?? .object([:])
                try tool.validate(arguments)
                let result = try await client.send(method: tool.method, params: arguments)
                return success(id: id, result: content(try jsonText(result), isError: false))
            } catch {
                return success(id: id, result: content(ClientDiagnostics.describe(error), isError: true))
            }
        default: return failure(id: id, code: -32601, message: "Unknown method: \(method)")
        }
    }

    func run() async {
        // readLine 只在专用 CLI 主流程中使用，EOF 正常退出。
        while let line = readLine() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let response: JSONValue?
            do {
                guard line.utf8.count <= CUAFraming.maxMessageBytes else {
                    throw ClientError(code: -32700, message: "MCP line exceeds 8 MiB")
                }
                response = await handle(try CUACodec.decode(JSONValue.self, from: Data(line.utf8)))
            } catch {
                response = failure(id: .null, code: -32700, message: "Invalid JSON: \(error.localizedDescription)")
            }
            if let response, let encoded = try? CUACodec.encode(response) {
                FileHandle.standardOutput.write(encoded + Data([10]))
            }
        }
    }

    private func content(_ text: String, isError: Bool) -> JSONValue {
        .object(["content": .array([.object(["type": "text", "text": .string(text)])]), "isError": .bool(isError)])
    }
    private func success(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }
    private func failure(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .int(code), "message": .string(message)])])
    }
}

func jsonText(_ value: JSONValue, pretty: Bool = false) throws -> String {
    let encoder = CUACodec.makeEncoder()
    if pretty { encoder.outputFormatting.insert(.prettyPrinted); encoder.outputFormatting.insert(.sortedKeys) }
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
