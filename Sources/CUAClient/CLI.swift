import Foundation
import CUACore

/// 手写参数解析：公共参数可放在子命令前后，每个参数只接受一次。
struct CLIArguments {
    var positionals: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    static let booleanOptions: Set<String> = ["json", "windows", "no-screenshot", "no-text", "exact", "no-ocr", "ocr-only", "help", "version"]
    static let valueOptions: Set<String> = ["socket", "timeout", "app", "query", "window", "screenshot-out", "out", "display", "element", "x", "y", "count", "button", "key", "duration-ms", "text", "direction", "pages", "value", "from-x", "from-y", "to-x", "to-y", "format", "prefix", "suffix", "selection", "action", "session", "limit"]

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { positionals.append(contentsOf: arguments.dropFirst(index + 1)); break }
            if argument == "-h" { flags.insert("help"); index += 1; continue }
            if !argument.hasPrefix("--") { positionals.append(argument); index += 1; continue }
            let pieces = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pieces[0])
            guard options[name] == nil, !flags.contains(name) else { throw Self.invalid("Duplicate --\(name)") }
            if Self.booleanOptions.contains(name) {
                guard pieces.count == 1 else { throw Self.invalid("--\(name) takes no value") }
                flags.insert(name)
            } else if Self.valueOptions.contains(name) {
                if pieces.count == 2 { options[name] = String(pieces[1]) }
                else {
                    index += 1
                    guard index < arguments.count else { throw Self.invalid("Missing value for --\(name)") }
                    options[name] = arguments[index]
                }
            } else { throw Self.invalid("Unknown option --\(name)") }
            index += 1
        }
    }

    var json: Bool { flags.contains("json") }
    func require(_ name: String) throws -> String {
        guard let value = options[name] else { throw Self.invalid("Missing --\(name)") }
        return value
    }
    func allow(_ names: Set<String>, positionals count: ClosedRange<Int> = 1...1) throws {
        let common: Set<String> = ["json", "socket", "timeout", "help"]
        let unknown = Set(options.keys).union(flags).subtracting(names.union(common))
        guard unknown.isEmpty else { throw Self.invalid("Unsupported option(s): \(unknown.sorted().map { "--" + $0 }.joined(separator: ", "))") }
        guard count.contains(positionals.count) else { throw Self.invalid("Unexpected or missing positional arguments") }
    }
    static func invalid(_ message: String) -> ClientError { ClientError(code: -32602, message: message) }
}

enum CUACommandLine {
    static let help = """
    cua — SwiftCUA macOS computer-use client
    Usage: cua [--socket PATH] [--timeout SECONDS] <command> [--json]
    Socket: --socket > SWIFTCUA_SOCKET > SwiftCUA default; timeout: 30 seconds.

      ping                         服务版本 / API 版本 / 权限
      permissions                  权限与 System Settings 修复指引
      apps [--windows]             应用列表
      windows                      窗口列表
      state --app ID [--no-screenshot] [--no-text] [--query S]
            [--window ID] [--screenshot-out PATH]
      screenshot [--app ID | --window ID | --display ID] --out PATH
      click --app ID (--element N | --x F --y F)
            [--count N] [--button left|right|middle] [--key CHORD]
      press-key --app ID --key CHORD [--duration-ms N]
      type --app ID --text S [--element N]
      scroll --app ID [--direction up|down|left|right] [--pages N]
             [--x F --y F] [--element N]
      set-value --app ID --element N --value S
      drag --app ID --from-x F --from-y F --to-x F --to-y F
      paste --app ID --text S [--format text|md|html]
      select-text --app ID --element N --text S [--prefix S] [--suffix S]
                  [--selection text|cursor_before|cursor_after]
      action --app ID --element N --action NAME
      find-text --app ID --text S [--exact] [--no-ocr] [--ocr-only] [--limit N]
      click-text --app ID --text S [--exact] [--no-ocr] [--ocr-only]
      call METHOD [JSON-PARAMS]     原始 JSON-RPC 调试透传
      session list                 本地 sessions/*.toml 清单
      doctor                       socket / ping / 权限 / 版本 checklist
      mcp                          MCP stdio server (newline-delimited JSON)
      --version | help

    App-targeted commands also accept --window ID and --session ID.
    Screenshot arrays write PATH, PATH-2.ext, PATH-3.ext, ... (existing files replaced).
    --json returns the complete service result; diagnostics always go to stderr.
    Start service manually: cua-service &
    """

    private static let commandTools: [String: String] = [
        "permissions": "get_permissions", "apps": "list_apps", "windows": "list_windows",
        "state": "get_app_state", "screenshot": "capture_screenshot", "click": "click",
        "press-key": "press_key", "type": "type_text", "scroll": "scroll", "set-value": "set_value",
        "drag": "drag", "paste": "paste", "select-text": "select_text", "action": "perform_secondary_action",
        "find-text": "find_text", "click-text": "click_text"
    ]
    private static let optionFields: [String: String] = [
        "app": "app", "window": "windowId", "display": "displayId", "session": "sessionId",
        "element": "elementIndex", "x": "x", "y": "y", "count": "clickCount", "button": "mouseButton",
        "key": "key", "duration-ms": "durationMilliseconds", "text": "text", "direction": "direction",
        "pages": "pages", "value": "value", "from-x": "fromX", "from-y": "fromY", "to-x": "toX",
        "to-y": "toY", "format": "format", "prefix": "prefix", "suffix": "suffix", "selection": "selectionType",
        "action": "action", "query": "query", "limit": "limit"
    ]

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let args = try CLIArguments(arguments)
            if args.flags.contains("version") {
                try args.allow(["version"], positionals: 0...0)
                let version: JSONValue = .object(["version": .string(CUAProtocolVersion.serviceVersion), "apiVersion": .string(CUAProtocolVersion.current)])
                print(args.json ? try jsonText(version) : "cua \(CUAProtocolVersion.serviceVersion) (\(CUAProtocolVersion.current))")
                return 0
            }
            if args.flags.contains("help") || args.positionals.isEmpty || args.positionals.first == "help" {
                if args.json { print(try jsonText(.object(["help": .string(help)]))) } else { print(help) }
                return 0
            }
            let command = args.positionals[0]
            let timeout: Double
            if let raw = args.options["timeout"] {
                guard let parsed = Double(raw), parsed.isFinite, parsed > 0 else { throw CLIArguments.invalid("--timeout must be positive seconds") }
                timeout = parsed
            } else { timeout = 30 }
            let client = SocketClient(socketPath: args.options["socket"], timeout: timeout)
            switch command {
            case "mcp":
                try args.allow([])
                await MCPServer(client: client).run()
            case "session":
                try args.allow([], positionals: 2...2)
                guard args.positionals[1] == "list" else { throw CLIArguments.invalid("Expected cua session list") }
                let result = try sessions()
                if args.json { print(try jsonText(result)) }
                else {
                    let rows = result["sessions"]?.arrayValue ?? []
                    if rows.isEmpty { print("No sessions in \(CUAPaths.sessionsDirectory.path)") }
                    for row in rows { print("=== \(row["file"]?.stringValue ?? "session") ===\n\(row["toml"]?.stringValue ?? "")") }
                }
            case "doctor":
                try args.allow([])
                return await doctor(client: client, json: args.json)
            case "ping":
                try args.allow([])
                let result = try await client.send(method: .ping)
                if args.json { print(try jsonText(result)) } else { printPing(result) }
            case "call":
                try args.allow([], positionals: 2...3)
                let params = args.positionals.count == 3 ? try CUACodec.decode(JSONValue.self, from: Data(args.positionals[2].utf8)) : nil
                let result = try await client.send(method: args.positionals[1], params: params)
                print(try jsonText(result, pretty: !args.json))
            default:
                guard let name = commandTools[command], let tool = MCPTools.all.first(where: { $0.name == name }) else {
                    throw CLIArguments.invalid("Unknown command: \(command)")
                }
                let params = try parameters(args, command: command, tool: tool)
                let result = try await client.send(method: tool.method, params: params)
                var paths: [String] = []
                if command == "screenshot" {
                    paths = try saveScreenshots(result["screenshots"]?.arrayValue ?? [], to: args.require("out"))
                } else if command == "state", let path = args.options["screenshot-out"] {
                    let state = result["state"] ?? result
                    paths = try saveScreenshots(state["screenshot"].map { [$0] } ?? [], to: path)
                }
                if args.json { print(try jsonText(result)) }
                else {
                    printResult(command: command, result: result)
                    for path in paths { print("Saved screenshot: \(path)") }
                }
            }
            return 0
        } catch {
            ClientDiagnostics.stderr(ClientDiagnostics.describe(error))
            return 1
        }
    }

    static func parameters(_ args: CLIArguments, command: String, tool: MCPTool) throws -> JSONValue {
        var allowed = Set(optionFields.filter { tool.properties[$0.value] != nil }.map(\.key))
        if command == "apps" { allowed.insert("windows") }
        if command == "state" { allowed.formUnion(["no-screenshot", "no-text", "screenshot-out"]) }
        if command == "screenshot" { allowed.insert("out"); _ = try args.require("out") }
        if command == "find-text" || command == "click-text" { allowed.formUnion(["exact", "no-ocr", "ocr-only"]) }
        try args.allow(allowed)
        var params: [String: JSONValue] = [:]
        for (option, field) in optionFields {
            guard let raw = args.options[option], let schema = tool.properties[field] else { continue }
            switch schema["type"]?.stringValue {
            case "integer":
                guard let value = Int(raw) else { throw CLIArguments.invalid("--\(option) must be an integer") }
                params[field] = .int(value)
            case "number":
                guard let value = Double(raw), value.isFinite else { throw CLIArguments.invalid("--\(option) must be a finite number") }
                params[field] = .double(value)
            default: params[field] = .string(raw)
            }
        }
        if command == "apps" { params["includeWindows"] = .bool(args.flags.contains("windows")) }
        if command == "state" {
            params["includeScreenshot"] = .bool(!args.flags.contains("no-screenshot"))
            params["includeText"] = .bool(!args.flags.contains("no-text"))
            if args.flags.contains("no-screenshot") && args.options["screenshot-out"] != nil {
                throw CLIArguments.invalid("--no-screenshot conflicts with --screenshot-out")
            }
        }
        if command == "click" {
            let hasElement = params["elementIndex"] != nil
            let hasX = params["x"] != nil; let hasY = params["y"] != nil
            guard (hasElement && !hasX && !hasY) || (!hasElement && hasX && hasY) else {
                throw CLIArguments.invalid("click requires either --element or both --x and --y")
            }
        }
        if command == "scroll", (params["x"] == nil) != (params["y"] == nil) {
            throw CLIArguments.invalid("scroll requires --x and --y together")
        }
        if command == "find-text" || command == "click-text" {
            params["exact"] = .bool(args.flags.contains("exact"))
            params["useOCR"] = .bool(!args.flags.contains("no-ocr"))
            params["ocrOnly"] = .bool(args.flags.contains("ocr-only"))
        }
        if command == "screenshot", ["app", "windowId", "displayId"].filter({ params[$0] != nil }).count > 1 {
            throw CLIArguments.invalid("screenshot accepts only one of --app, --window, --display")
        }
        let result = JSONValue.object(params)
        try tool.validate(result)
        return result
    }

    private static func printPing(_ value: JSONValue) {
        let server = value["server"] ?? value
        print("Service: \(server["serverVersion"]?.stringValue ?? "unknown")\nAPI: \(server["apiVersion"]?.stringValue ?? "unknown")\nPlatform: \(server["platform"]?.stringValue ?? "macOS")")
        if let permissions = server["permissions"] ?? value["permissions"] { printPermissions(permissions) }
    }
    private static func printPermissions(_ value: JSONValue) {
        let permissions = value["permissions"] ?? value
        print("Screen Recording: \(permissions["screenRecording"]?.boolValue == true ? "granted" : "missing")")
        print("Accessibility: \(permissions["accessibility"]?.boolValue == true ? "granted" : "missing")")
        print(ClientDiagnostics.permissionHelp)
    }
    private static func printResult(command: String, result: JSONValue) {
        switch command {
        case "permissions": printPermissions(result)
        case "find-text":
            let rows = result["matches"]?.arrayValue ?? []
            if rows.isEmpty { print("No matches") }
            else {
                table(headers: ["#", "TEXT", "SOURCE", "RECT"], rows: rows.enumerated().map { index, row in
                    let rect = row["rect"]
                    return [String(index), row["text"]?.stringValue ?? "",
                            row["source"]?.stringValue ?? "",
                            "\(Int(rect?["x"]?.doubleValue ?? 0)),\(Int(rect?["y"]?.doubleValue ?? 0)) \(Int(rect?["width"]?.doubleValue ?? 0))×\(Int(rect?["height"]?.doubleValue ?? 0))"]
                })
            }
        case "click-text":
            let match = result["match"]
            print("Clicked: \(match?["text"]?.stringValue ?? "") [\(match?["source"]?.stringValue ?? "")]")
        case "apps":
            let apps = result["apps"]?.arrayValue ?? []
            table(headers: ["ID", "NAME", "RUNNING", "WINDOWS"], rows: apps.map {
                [$0["id"]?.stringValue ?? "", $0["displayName"]?.stringValue ?? "—",
                 $0["isRunning"]?.boolValue.map { $0 ? "yes" : "no" } ?? "?",
                 String($0["windows"]?.arrayValue?.count ?? 0)]
            })
        case "windows":
            table(headers: ["ID", "APP", "TITLE", "FOCUSED"], rows: (result["windows"]?.arrayValue ?? []).map {
                [String($0["id"]?.intValue ?? 0), $0["app"]?.stringValue ?? "", $0["title"]?.stringValue ?? "—", $0["isFocused"]?.boolValue == true ? "yes" : "no"]
            })
        case "state":
            let state = result["state"] ?? result
            print(state["text"]?.stringValue ?? state["accessibility"]?["tree"]?.stringValue ?? "No text returned")
            if state["screenshot"] != nil && state["screenshot"] != .null { print("Screenshot available (use --screenshot-out PATH to save).") }
        case "screenshot": break
        default: print("OK")
        }
    }
    private static func table(headers: [String], rows: [[String]]) {
        let cleaned = rows.map { $0.map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ") } }
        let widths = headers.indices.map { column in min(72, ([headers] + cleaned).map { $0[column].count }.max() ?? 0) }
        for row in [headers] + cleaned {
            print(row.enumerated().map { index, text in
                let short = text.count > widths[index] ? String(text.prefix(widths[index] - 1)) + "…" : text
                return short + String(repeating: " ", count: max(0, widths[index] - short.count))
            }.joined(separator: "  "))
        }
        if rows.isEmpty { print("(none)") }
    }

    /// 只解码数据 URL，不联网；多显示器截图自动追加序号。
    private static func saveScreenshots(_ screenshots: [JSONValue], to path: String) throws -> [String] {
        guard !screenshots.isEmpty else { throw ClientError(code: 1011, message: "No screenshot returned; check Screen Recording permission and target window") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var paths: [String] = []
        for (index, screenshot) in screenshots.enumerated() {
            guard let url = screenshot["url"]?.stringValue, url.hasPrefix("data:image/"),
                  let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
                throw ClientError(code: 1011, message: "Screenshot is not a valid base64 image data URL")
            }
            var target = base
            if index > 0 {
                // 以连字符追加序号，保留用户选择的文件扩展名。
                target = base.deletingLastPathComponent().appendingPathComponent(base.deletingPathExtension().lastPathComponent + "-\(index + 1)" + (base.pathExtension.isEmpty ? "" : "." + base.pathExtension))
            }
            try data.write(to: target, options: .atomic)
            paths.append(target.path)
        }
        return paths
    }

    private static func sessions() throws -> JSONValue {
        let directory = CUAPaths.sessionsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return .object(["sessions": .array([])]) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.pathExtension == "toml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let entries = try files.compactMap { file -> JSONValue? in
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return .object(["file": .string(file.lastPathComponent), "path": .string(file.path), "toml": .string(try String(contentsOf: file, encoding: .utf8))])
        }
        return .object(["sessions": .array(entries)])
    }

    private static func doctor(client: SocketClient, json: Bool) async -> Int32 {
        var checks: [JSONValue] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            checks.append(.object(["name": .string(name), "ok": .bool(ok), "detail": .string(detail)]))
        }
        check("socket exists", FileManager.default.fileExists(atPath: client.socketPath), client.socketPath)
        do {
            let ping = try await client.send(method: .ping)
            check("connectivity", true, "Unix socket connected")
            check("ping", true, "JSON-RPC response received")
            check("API version", SocketClient.versionMatches(ping), (ping["server"] ?? ping)["apiVersion"]?.stringValue ?? "missing")
            do {
                let result = try await client.send(method: .getPermissions)
                let permissions = result["permissions"] ?? result
                check("Screen Recording", permissions["screenRecording"]?.boolValue == true, "Privacy & Security → Screen Recording")
                check("Accessibility", permissions["accessibility"]?.boolValue == true, "Privacy & Security → Accessibility")
            } catch { check("permissions", false, ClientDiagnostics.describe(error)) }
        } catch {
            check("connectivity / ping", false, ClientDiagnostics.describe(error))
            check("API version", false, "Unavailable until service responds")
            check("permissions", false, "Unavailable until service responds")
        }
        let ok = checks.allSatisfy { $0["ok"]?.boolValue == true }
        let result: JSONValue = .object(["ok": .bool(ok), "checks": .array(checks), "permissionHelp": .string(ClientDiagnostics.permissionHelp)])
        if json { print((try? jsonText(result)) ?? "{}") }
        else {
            for item in checks { print("[\(item["ok"]?.boolValue == true ? "PASS" : "FAIL")] \(item["name"]?.stringValue ?? ""): \(item["detail"]?.stringValue ?? "")") }
            if !ok { print(ClientDiagnostics.permissionHelp) }
        }
        return ok ? 0 : 1
    }
}
