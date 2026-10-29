import XCTest
import Foundation
import Darwin
@testable import CUAService
import CUACore

actor FakeEngine: CUAEngine {
    var calls: [String] = []
    var granted = CUAPermissions(screenRecording: true, accessibility: true)
    var listDelay: Duration = .zero
    func setPermissions(_ value: CUAPermissions) { granted = value }
    func setDelay(_ value: Duration) { listDelay = value }
    func permissions() async -> CUAPermissions { granted }
    func listApps(includeWindows: Bool) async throws -> [CUAAppInfo] {
        calls.append("listApps")
        try await Task.sleep(for: listDelay)
        return [CUAAppInfo(id: "test.app", displayName: "Fake")]
    }
    func listWindows() async throws -> [CUAWindowInfo] { [] }
    func getAppState(_ params: GetAppStateParams) async throws -> CUAAppState { CUAAppState(app: params.app, text: "Fake tree") }
    func click(_ params: ClickParams) async throws { calls.append("click") }
    func pressKey(_ params: PressKeyParams) async throws { calls.append("pressKey") }
    func typeText(_ params: TypeTextParams) async throws { calls.append("typeText") }
    func scroll(_ params: ScrollParams) async throws { calls.append("scroll") }
    func setValue(_ params: SetValueParams) async throws { calls.append("setValue") }
    func drag(_ params: DragParams) async throws { calls.append("drag") }
    func paste(_ params: PasteParams) async throws { calls.append("paste") }
    func selectText(_ params: SelectTextParams) async throws { calls.append("selectText") }
    func performSecondaryAction(_ params: PerformSecondaryActionParams) async throws { calls.append("secondary") }
    func captureScreenshot(_ params: CaptureScreenshotParams) async throws -> [CUAScreenshot] { [] }
    func resetSessionState() async { calls.append("reset") }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

final class ServiceTests: XCTestCase, @unchecked Sendable {
    private var home: URL!
    private var previousHome: String?
    override func setUpWithError() throws {
        previousHome = ProcessInfo.processInfo.environment["SWIFTCUA_HOME"]
        // 使用短路径，避免 macOS sockaddr_un 的 104 字节限制。
        home = URL(fileURLWithPath: "/tmp/scua-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("SWIFTCUA_HOME", home.path, 1)
        try CUAPaths.ensureDirectories()
    }
    override func tearDownWithError() throws {
        if let previousHome { setenv("SWIFTCUA_HOME", previousHome, 1) }
        else { unsetenv("SWIFTCUA_HOME") }
        // 路径来自本测试创建的随机临时目录，删除前再次校验。
        guard home.path.hasPrefix("/tmp/scua-") else { XCTFail("Unexpected cleanup path"); return }
        try FileManager.default.removeItem(at: home)
    }
    private func fixture(autoAuthorize: Bool = true) throws -> (FakeEngine, SessionStore, RequestRouter) {
        let engine = FakeEngine()
        let sessions = try SessionStore(directory: home.appendingPathComponent("sessions"), autoAuthorizeApps: autoAuthorize)
        return (engine, sessions, RequestRouter(engine: engine, sessions: sessions))
    }
    private func ping(_ router: RequestRouter, id: String = "test-session") async -> RPCResponse? {
        await router.route(RPCRequest(id: .int(1), method: "ping", params: .object([
            "clientApiVersion": .string(CUAProtocolVersion.current), "sessionId": .string(id)
        ])))
    }
    func testPingReturnsServerInfoAndGeneratedSession() async throws {
        let (_, _, router) = try fixture()
        let response = await router.route(RPCRequest(id: .int(1), method: "ping", params: try CUACodec.jsonValue(PingParams(clientApiVersion: CUAProtocolVersion.current))))
        XCTAssertEqual(response?.result?["serverVersion"]?.stringValue, CUAProtocolVersion.serviceVersion)
        XCTAssertEqual(response?.result?["apiVersion"]?.stringValue, CUAProtocolVersion.current)
        let id = try XCTUnwrap(response?.result?["sessionId"]?.stringValue)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions/\(id).toml").path))
    }
    func testUnknownMethodAndInvalidRequests() async throws {
        let (_, _, router) = try fixture()
        let unknown = await router.route(RPCRequest(id: .int(1), method: "missing"))
        XCTAssertEqual(unknown?.error?.code, CUAErrorCode.methodNotFound.rawValue)
        let malformed = await router.handle(Data("{".utf8))
        XCTAssertEqual(malformed?.error?.code, CUAErrorCode.parseError.rawValue)
        let wrongVersion = await router.handle(Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8))
        XCTAssertEqual(wrongVersion?.error?.code, CUAErrorCode.invalidRequest.rawValue)
        let badParams = await router.route(RPCRequest(id: .int(2), method: "click", params: .object([:])))
        XCTAssertEqual(badParams?.error?.code, CUAErrorCode.invalidParams.rawValue)
        XCTAssertTrue(badParams?.error?.message.contains("click") == true)
    }
    func testListAppsAndDeadline() async throws {
        let (engine, _, router) = try fixture()
        let response = await router.route(RPCRequest(id: .int(1), method: "listApps"))
        XCTAssertEqual(response?.result?["apps"]?.arrayValue?.first?["id"]?.stringValue, "test.app")
        await engine.setDelay(.seconds(2))
        let timed = await router.route(RPCRequest(id: .int(2), method: "listApps", params: .object(["deadlineMilliseconds": .int(10)])))
        XCTAssertEqual(timed?.error?.code, CUAErrorCode.timeout.rawValue)
    }
    func testAuthorizationPendingAndExplicitApproval() async throws {
        let (engine, sessions, router) = try fixture(autoAuthorize: false)
        _ = await ping(router)
        let request = RPCRequest(id: .int(2), method: "click", params: .object(["app": "test.app", "sessionId": "test-session", "elementIndex": 0]))
        let denied = await router.route(request)
        XCTAssertEqual(denied?.error?.code, CUAErrorCode.appNotAuthorized.rawValue)
        XCTAssertEqual(denied?.error?.data?["app"]?.stringValue, "test.app")
        let pending = await sessions.pending
        XCTAssertEqual(pending.count, 1)
        try await sessions.authorizeApp(sessionId: "test-session", app: "test.app")
        let allowed = await router.route(request)
        XCTAssertNil(allowed?.error)
        let calls = await engine.calls
        XCTAssertEqual(calls, ["click"])
        let reloaded = try SessionStore(directory: home.appendingPathComponent("sessions"), autoAuthorizeApps: false)
        try await reloaded.checkAuthorization(sessionId: "test-session", app: "test.app")
    }
    func testPermissionGateAndMissingSession() async throws {
        let (engine, _, router) = try fixture()
        let request = RPCRequest(id: .int(2), method: "getAppState", params: .object(["app": "test.app", "sessionId": "test-session"]))
        let missing = await router.route(request)
        XCTAssertEqual(missing?.error?.code, CUAErrorCode.sessionNotFound.rawValue)
        _ = await ping(router)
        await engine.setPermissions(CUAPermissions(screenRecording: true, accessibility: false))
        let denied = await router.route(request)
        XCTAssertEqual(denied?.error?.data?["permission"]?.stringValue, "Accessibility")
        await engine.setPermissions(CUAPermissions(screenRecording: false, accessibility: true))
        let capture = await router.route(request)
        XCTAssertEqual(capture?.error?.data?["permission"]?.stringValue, "ScreenRecording")
    }
    func testEndSessionDeletesFileAndResetsEngine() async throws {
        let (engine, _, router) = try fixture()
        _ = await ping(router)
        let path = home.appendingPathComponent("sessions/test-session.toml").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let response = await router.route(RPCRequest(method: "endSession", params: .object(["sessionId": "test-session"])))
        XCTAssertNil(response)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let calls = await engine.calls
        XCTAssertTrue(calls.contains("reset"))
    }
    func testSessionPathTraversalRejected() async throws {
        let (_, _, router) = try fixture()
        let response = await ping(router, id: "../../bad")
        XCTAssertEqual(response?.error?.code, CUAErrorCode.invalidParams.rawValue)
    }
    func testTTLRemovesPersistedSession() async throws {
        let clock = TestClock()
        let sessions = try SessionStore(directory: home.appendingPathComponent("sessions"), ttl: 60, now: { clock.now() })
        _ = try await sessions.ping(sessionId: "expiring")
        clock.advance(61)
        await sessions.removeExpired()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions/expiring.toml").path))
    }
    func testConfigurationAndCommandLine() throws {
        let config = try CUACodec.decode(ServiceConfiguration.self, from: Data(#"{"autoAuthorizeApps":false,"requirePeerValidation":true}"#.utf8))
        XCTAssertFalse(config.autoAuthorizeApps)
        XCTAssertTrue(config.requirePeerValidation)
        XCTAssertTrue(config.allowUnsigned)
        let options = try ServiceOptions(arguments: ["--home", home.path, "--auto-authorize", "false", "--require-peer", "--foreground"])
        XCTAssertEqual(options.home, home.path)
        XCTAssertEqual(options.autoAuthorize, false)
        XCTAssertTrue(options.requirePeer)
        XCTAssertThrowsError(try ServiceOptions(arguments: ["--no-peer-check", "--require-peer"]))
        XCTAssertThrowsError(try ServiceOptions(arguments: ["--socket"]))
    }
    func testPeerPolicyDefaultsAndAllowLists() {
        var configuration = ServiceConfiguration()
        let unsigned = PeerValidator.Identity(pid: 100, uid: 501, validSignature: false)
        XCTAssertTrue(PeerValidator(configuration: configuration).accepts(unsigned))
        XCTAssertFalse(PeerValidator(configuration: configuration).accepts(.init(pid: 0, uid: 501, validSignature: false)))
        XCTAssertFalse(PeerValidator(configuration: configuration).accepts(.init(pid: 100, uid: 0, validSignature: true)))
        configuration.requirePeerValidation = true
        configuration.allowedTeamIdentifiers = ["TEAM"]
        XCTAssertFalse(PeerValidator(configuration: configuration).accepts(unsigned))
        XCTAssertTrue(PeerValidator(configuration: configuration).accepts(.init(pid: 100, uid: 501, teamIdentifier: "TEAM", cdhash: "abcd", validSignature: true)))
    }
    func testLengthPrefixFragmentationAndOversize() throws {
        var decoder = CUAStreamDecoder()
        let frame = CUAFraming.encode(Data("hello".utf8))
        var payloads: [Data] = []
        for byte in frame { payloads += try decoder.append(Data([byte])) }
        XCTAssertEqual(payloads, [Data("hello".utf8)])
        XCTAssertThrowsError(try decoder.append(Data([1, 0, 128, 0])))
    }
    func testSocketPermissionsSingleInstanceAndFragmentedJSON() async throws {
        let (_, _, router) = try fixture()
        let path = home.appendingPathComponent("IPC/\(UUID().uuidString.prefix(8)).sock").path
        let server = SocketServer(socketPath: path, router: router)
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let second = SocketServer(socketPath: path, router: router)
        XCTAssertThrowsError(try second.start())
        XCTAssertTrue(server.isRunning)
        let response = try await Task.detached {
            try Self.exchange(path: path, payload: Data("{".utf8))
        }.value
        XCTAssertEqual(response.error?.code, CUAErrorCode.parseError.rawValue)
        let apps = try await Task.detached {
            try Self.exchange(path: path, payload: CUACodec.encode(RPCRequest(id: .int(7), method: "listApps")))
        }.value
        XCTAssertEqual(apps.id, .int(7))
        XCTAssertEqual(apps.result?["apps"]?.arrayValue?.count, 1)
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".lock"))
    }
    func testStaleSocketReplacedAndIdleConnectionClosed() async throws {
        let (_, _, router) = try fixture()
        let path = home.appendingPathComponent("IPC/stale.sock").path
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(stale, 0)
        XCTAssertEqual(try withUnixAddress(path) { Darwin.bind(stale, $0, $1) }, 0)
        Darwin.close(stale)
        let server = SocketServer(socketPath: path, router: router, idleTimeout: 0.05)
        try server.start()
        defer { server.stop() }
        let count = try await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard try withUnixAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else {
                throw CUAError(code: .internalError, message: "test idle connect")
            }
            var byte: UInt8 = 0
            return recv(fd, &byte, 1, 0)
        }.value
        XCTAssertEqual(count, 0)
    }
    private static func exchange(path: String, payload: Data) throws -> RPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CUAError(code: .internalError, message: "test socket") }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard try withUnixAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else { throw CUAError(code: .internalError, message: "test connect") }
        let frame = CUAFraming.encode(payload)
        for byte in frame {
            var byte = byte
            guard Darwin.send(fd, &byte, 1, 0) == 1 else { throw CUAError(code: .internalError, message: "test send") }
        }
        var decoder = CUAStreamDecoder()
        while true {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw CUAError(code: .timeout, message: "test receive") }
            if let data = try decoder.append(Data(bytes.prefix(count))).first {
                return try CUACodec.decode(RPCResponse.self, from: data)
            }
        }
    }
}
