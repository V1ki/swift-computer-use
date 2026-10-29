import XCTest
import Foundation
import Darwin
@testable import CUAClient
import CUACore

/// 测试仅连接临时 Unix socket，不加载引擎，不触发 TCC 或真实输入。
final class FakeSocketServer: @unchecked Sendable {
    enum Mode: Sendable { case normal, silent, wrongVersion, remoteError }
    let path: String
    private let listener: Int32
    private let mode: Mode
    private let lock = NSLock()
    private var stopping = false
    private var requests: [RPCRequest] = []
    private let done = DispatchSemaphore(value: 0)

    init(mode: Mode = .normal) throws {
        self.mode = mode
        path = "/tmp/swiftcua-test-\(UUID().uuidString).sock"
        listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ClientError(code: -1, message: "socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, Darwin.listen(listener, 4) == 0 else {
            Darwin.close(listener)
            throw ClientError(code: -1, message: "bind/listen failed")
        }
        DispatchQueue(label: "swiftcua.fake.socket").async { self.serve() }
    }

    var recorded: [RPCRequest] { lock.withLock { requests } }

    func stop() {
        lock.withLock { stopping = true }
        _ = done.wait(timeout: .now() + 3)
        Darwin.close(listener)
        // 删除前验证目标确为本测试生成的绝对 socket 路径。
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        precondition(resolved.hasPrefix("/tmp/swiftcua-test-") && resolved.hasSuffix(".sock"))
        _ = Darwin.unlink(resolved)
    }

    private func serve() {
        defer { done.signal() }
        var peer: Int32 = -1
        defer { if peer >= 0 { Darwin.close(peer) } }
        var decoder = CUAStreamDecoder()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !lock.withLock({ stopping }) {
            var item = pollfd(fd: peer >= 0 ? peer : listener, events: Int16(POLLIN), revents: 0)
            guard poll(&item, 1, 25) > 0 else { continue }
            if peer < 0 {
                peer = Darwin.accept(listener, nil, nil)
                if peer >= 0 {
                    var one: Int32 = 1
                    _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
                }
                continue
            }
            let count = recv(peer, &buffer, buffer.count, 0)
            if count <= 0 { Darwin.close(peer); peer = -1; decoder = CUAStreamDecoder(); continue }
            guard let frames = try? decoder.append(Data(buffer.prefix(count))) else { return }
            for frame in frames {
                guard let request = try? CUACodec.decode(RPCRequest.self, from: frame) else { continue }
                lock.withLock { requests.append(request) }
                guard let id = request.id, mode != .silent else { continue }
                let response: RPCResponse
                if request.method == "ping" {
                    let info = CUAServerInfo(serverVersion: "test-service", apiVersion: mode == .wrongVersion ? "Other-IPC-99" : CUAProtocolVersion.current, permissions: CUAPermissions(screenRecording: true, accessibility: false))
                    response = RPCResponse(id: id, result: .object(["server": try! CUACodec.jsonValue(info), "sessionId": "test-session"]))
                } else if mode == .remoteError {
                    response = RPCResponse(id: id, error: .permissionMissing("Accessibility"))
                } else if request.method == "listApps" {
                    response = RPCResponse(id: id, result: try! CUACodec.jsonValue(ListAppsResult(apps: [CUAAppInfo(id: "test.app", displayName: "Fake App", isRunning: true)])))
                } else if request.method == "nullResult" {
                    response = RPCResponse(id: id, result: .null)
                } else {
                    response = RPCResponse(id: id, result: .object(["ok": true]))
                }
                // 插入无关 id，并将目标响应切成单字节头，覆盖匹配和任意分包。
                let unrelated = try! CUAFraming.encodeJSON(RPCResponse(id: .int(-42), result: .null), using: CUACodec.makeEncoder())
                let output = try! CUAFraming.encodeJSON(response, using: CUACodec.makeEncoder())
                write(unrelated, to: peer)
                write(Data(output.prefix(1)), to: peer)
                write(Data(output.dropFirst(1).prefix(2)), to: peer)
                write(Data(output.dropFirst(3)), to: peer)
            }
        }
    }

    private func write(_ data: Data, to fd: Int32) {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, 0) }
            if count <= 0 { return }
            offset += count
        }
    }
}

final class WarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var messages: [String] { lock.withLock { values } }
}

@MainActor
final class CUAClientTests: XCTestCase {
    func testSocketPingAndRequestIDMatching() async throws {
        let server = try FakeSocketServer(); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 2)
        let ping = try await client.send(method: .ping)
        XCTAssertEqual(ping["server"]?["serverVersion"], "test-service")
        XCTAssertTrue(SocketClient.versionMatches(ping))
        let apps = try await client.send(method: .listApps, params: .object(["includeWindows": true]))
        XCTAssertEqual(apps["apps"]?.arrayValue?.first?["id"], "test.app")
        XCTAssertEqual(server.recorded.map(\.method), ["ping", "listApps"])
        XCTAssertEqual(server.recorded[0].params?["clientApiVersion"], .string(CUAProtocolVersion.current))
        XCTAssertNotEqual(server.recorded[0].id, server.recorded[1].id)
        XCTAssertEqual(server.recorded[1].params?["sessionId"], "test-session")
    }

    func testAutomaticHandshakeAndConcurrentCalls() async throws {
        let server = try FakeSocketServer(); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 2)
        async let first = client.send(method: .listApps)
        async let second = client.send(method: .listApps)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(server.recorded.map(\.method), ["ping", "listApps", "listApps"])
    }

    func testNullResultIsValidJSONRPC() async throws {
        let server = try FakeSocketServer(); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 1)
        let result = try await client.send(method: "nullResult")
        XCTAssertEqual(result, .null)
    }

    func testExplicitSessionOverridesHandshakeSession() async throws {
        let server = try FakeSocketServer(); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 1)
        _ = try await client.send(method: .listApps, params: .object(["sessionId": "explicit-session"]))
        XCTAssertEqual(server.recorded[0].params?["sessionId"], "explicit-session")
        XCTAssertEqual(server.recorded[1].params?["sessionId"], "explicit-session")
    }

    func testNotificationDoesNotWaitForResponse() async throws {
        let server = try FakeSocketServer(); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 1)
        try await client.endSession("fake-session")
        // 后续请求确保服务已消费此前通知，避免依赖 sleep。
        _ = try await client.send(method: .listApps)
        let notification = try XCTUnwrap(server.recorded.first { $0.method == "endSession" })
        XCTAssertNil(notification.id)
        XCTAssertEqual(notification.params?["sessionId"], "fake-session")
    }

    func testTimeout() async throws {
        let server = try FakeSocketServer(mode: .silent); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 0.08)
        let start = Date()
        do { _ = try await client.send(method: .ping); XCTFail("Expected timeout") }
        catch let error as ClientError { XCTAssertEqual(error.code, CUAErrorCode.timeout.rawValue) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testConnectionFailureIsActionable() async {
        let client = SocketClient(socketPath: "/tmp/swiftcua-missing-\(UUID().uuidString).sock", timeout: 0.2)
        do { _ = try await client.send(method: .ping); XCTFail("Expected failure") }
        catch {
            let message = ClientDiagnostics.describe(error)
            XCTAssertTrue(message.contains("service not running; start with: cua-service &"))
            XCTAssertTrue(message.contains("--socket"))
        }
    }

    func testSocketOverridePrecedence() {
        let env = ["SWIFTCUA_SOCKET": "/tmp/from-env.sock"]
        XCTAssertEqual(SocketClient(environment: env).socketPath, "/tmp/from-env.sock")
        XCTAssertEqual(SocketClient(socketPath: "/tmp/from-cli.sock", environment: env).socketPath, "/tmp/from-cli.sock")
        XCTAssertEqual(SocketClient(environment: [:]).socketPath, CUAPaths.socketPath.path)
    }

    func testVersionMismatchOnlyWarns() async throws {
        let server = try FakeSocketServer(mode: .wrongVersion); defer { server.stop() }
        let recorder = WarningRecorder()
        let client = SocketClient(socketPath: server.path, timeout: 1, warning: { recorder.add($0) })
        let result = try await client.send(method: .listApps)
        XCTAssertNotNil(result["apps"])
        XCTAssertEqual(recorder.messages.count, 1)
        XCTAssertTrue(recorder.messages[0].contains("server.apiVersion"))
    }

    func testRemotePermissionErrorIncludesRepairLinks() async throws {
        let server = try FakeSocketServer(mode: .remoteError); defer { server.stop() }
        let client = SocketClient(socketPath: server.path, timeout: 1)
        do { _ = try await client.send(method: .click); XCTFail("Expected permission error") }
        catch {
            let text = ClientDiagnostics.describe(error)
            XCTAssertTrue(text.contains("[1001]"))
            XCTAssertTrue(text.contains("Privacy_Accessibility"))
            XCTAssertTrue(text.contains("Privacy_ScreenCapture"))
        }
    }

    func testMCPToolNamesSchemasAndRequiredFields() async throws {
        let server = MCPServer(client: SocketClient(socketPath: "/tmp/not-used.sock"))
        let response = await server.handle(request("tools/list"))
        let tools = try XCTUnwrap(response?["result"]?["tools"]?.arrayValue)
        let required: [String: [String]] = [
            "list_apps": [], "list_windows": [], "get_app_state": ["app"], "click": ["app"],
            "press_key": ["app", "key"], "type_text": ["app", "text"], "scroll": ["app"],
            "set_value": ["app", "elementIndex", "value"], "drag": ["app", "fromX", "fromY", "toX", "toY"],
            "paste": ["app", "text"], "select_text": ["app", "elementIndex", "text"],
            "perform_secondary_action": ["app", "elementIndex", "action"], "capture_screenshot": [],
            "find_text": ["app", "text"], "click_text": ["app", "text"], "get_permissions": []
        ]
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set(required.keys))
        XCTAssertEqual(tools.count, 16)
        for tool in tools {
            let name = try XCTUnwrap(tool["name"]?.stringValue)
            let schema = try XCTUnwrap(tool["inputSchema"])
            XCTAssertEqual(schema["type"], "object")
            XCTAssertEqual(schema["additionalProperties"], false)
            XCTAssertEqual(Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []), Set(required[name]!))
            for field in required[name]! { XCTAssertNotNil(schema["properties"]?[field]) }
        }
        let scroll = try XCTUnwrap(tools.first { $0["name"] == "scroll" })
        XCTAssertEqual(Set(scroll["inputSchema"]?["properties"]?.objectValue?.keys.map { $0 } ?? []),
                       Set(["app", "sessionId", "direction", "elementIndex", "x", "y", "pages", "pixels", "scrollX", "scrollY", "windowId"]))
    }

    func testMCPInitializeAndVersionNegotiation() async throws {
        let server = MCPServer(client: SocketClient(socketPath: "/tmp/not-used.sock"))
        for version in ["2024-11-05", "2025-06-18", "unknown-version"] {
            let response = await server.handle(request("initialize", params: .object([
                "protocolVersion": .string(version), "capabilities": .object([:]),
                "clientInfo": .object(["name": "test", "version": "1.0"])
            ])))
            XCTAssertEqual(response?["id"], 7)
            XCTAssertEqual(response?["result"]?["protocolVersion"], .string(version == "unknown-version" ? MCPServer.protocolVersion : version))
            XCTAssertEqual(response?["result"]?["serverInfo"]?["name"], "swiftcua")
            XCTAssertNotNil(response?["result"]?["capabilities"]?["tools"])
        }
        let notification = await server.handle(.object(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNil(notification)
        let ping = await server.handle(request("ping"))
        XCTAssertEqual(ping?["result"], .object([:]))
    }

    func testMCPToolCallAndServiceUnavailable() async throws {
        let fake = try FakeSocketServer(); defer { fake.stop() }
        let server = MCPServer(client: SocketClient(socketPath: fake.path, timeout: 1))
        let response = await server.handle(request("tools/call", params: .object(["name": "list_apps", "arguments": .object(["includeWindows": true])])))
        XCTAssertEqual(response?["result"]?["isError"], false)
        let text = try XCTUnwrap(response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let value = try CUACodec.decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(value["apps"]?.arrayValue?.first?["id"], "test.app")
        let unavailable = MCPServer(client: SocketClient(socketPath: "/tmp/no-service-\(UUID().uuidString).sock", timeout: 0.1))
        let failure = await unavailable.handle(request("tools/call", params: .object(["name": "get_permissions"])))
        XCTAssertEqual(failure?["result"]?["isError"], true)
        XCTAssertTrue(failure?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("cua-service &") == true)
    }

    func testMCPInvalidRequestsAndArguments() async {
        let server = MCPServer(client: SocketClient(socketPath: "/tmp/not-used.sock"))
        let malformed = await server.handle(.array([]))
        XCTAssertEqual(malformed?["error"]?["code"], -32600)
        let unknown = await server.handle(request("unknown"))
        XCTAssertEqual(unknown?["error"]?["code"], -32601)
        let missing = await server.handle(request("initialize"))
        XCTAssertEqual(missing?["error"]?["code"], -32602)
        let invalid = await server.handle(request("tools/call", params: .object(["name": "set_value", "arguments": .object(["app": "test.app"])])))
        XCTAssertEqual(invalid?["result"]?["isError"], true)
    }

    func testCLIParameterMappingAndValidation() throws {
        let click = try XCTUnwrap(MCPTools.all.first { $0.name == "click" })
        let args = try CLIArguments(["--json", "click", "--app", "test.app", "--x", "-2.5", "--y", "42", "--count", "2", "--button", "right"])
        let params = try CUACommandLine.parameters(args, command: "click", tool: click)
        XCTAssertEqual(params["x"], .double(-2.5))
        XCTAssertEqual(params["clickCount"], 2)
        XCTAssertEqual(params["mouseButton"], "right")
        XCTAssertThrowsError(try CUACommandLine.parameters(CLIArguments(["click", "--app", "test.app", "--element", "1", "--x", "2", "--y", "3"]), command: "click", tool: click))
        XCTAssertThrowsError(try CLIArguments(["apps", "--unknown"]))
        XCTAssertThrowsError(try CLIArguments(["apps", "--json", "--json"]))
        let state = try XCTUnwrap(MCPTools.all.first { $0.name == "get_app_state" })
        let stateParams = try CUACommandLine.parameters(CLIArguments(["state", "--app", "test.app", "--no-screenshot", "--window", "12"]), command: "state", tool: state)
        XCTAssertEqual(stateParams["includeScreenshot"], false)
        XCTAssertEqual(stateParams["windowId"], 12)
    }

    private func request(_ method: String, params: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": 7, "method": .string(method), "params": params])
    }
}
