import Foundation
import CUACore

struct PermissionGate: Sendable {
    let engine: any CUAEngine
    func check(accessibility: Bool = false, screenRecording: Bool = false) async throws {
        let permissions = await engine.permissions()
        if accessibility && !permissions.accessibility { throw CUAError.permissionMissing("Accessibility") }
        if screenRecording && !permissions.screenRecording { throw CUAError.permissionMissing("ScreenRecording") }
    }
}

actor RequestRouter {
    let engine: any CUAEngine
    let sessions: SessionStore
    private let gate: PermissionGate
    private let log = CUALogger(CUALog.service)

    init(engine: any CUAEngine, sessions: SessionStore) {
        self.engine = engine
        self.sessions = sessions
        gate = PermissionGate(engine: engine)
    }

    /// 语法错误和合法 JSON 的错误请求分别映射到 JSON-RPC 的两个错误码。
    func handle(_ payload: Data) async -> RPCResponse? {
        do { _ = try CUACodec.decode(JSONValue.self, from: payload) }
        catch {
            log.warning("method=<parse> elapsedMs=0 error=-32700")
            return RPCResponse(id: nil, error: CUAError(code: .parseError, message: "Invalid JSON"))
        }
        let request: RPCRequest
        do { request = try CUACodec.decode(RPCRequest.self, from: payload) }
        catch {
            log.warning("method=<invalid> elapsedMs=0 error=-32600")
            return RPCResponse(id: nil, error: CUAError(code: .invalidRequest, message: "Invalid JSON-RPC request"))
        }
        return await route(request)
    }

    func route(_ request: RPCRequest) async -> RPCResponse? {
        let start = ContinuousClock.now
        log.debug("method=\(request.method) paramKeys=\((request.params?.objectValue?.keys.sorted() ?? []).joined(separator: ","))")
        let response: RPCResponse
        do {
            guard request.jsonrpc == "2.0" else { throw CUAError(code: .invalidRequest, message: "Expected JSON-RPC 2.0") }
            guard let method = CUAMethod(rawValue: request.method) else {
                throw CUAError(code: .methodNotFound, message: "Unknown method: \(request.method)")
            }
            var milliseconds = method == .ping ? 5000 : 30000
            if let deadline = request.params?["deadlineMilliseconds"] {
                guard case .int(let value) = deadline, value > 0, value <= 86_400_000 else {
                    throw CUAError.invalidParams("deadlineMilliseconds must be between 1 and 86400000", method: method.rawValue)
                }
                milliseconds = value
            }
            let timeout = milliseconds
            // 结构化并发要求引擎在长操作中响应取消；超时后不会遗留未归属的任务。
            let result = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await self.dispatch(method, params: request.params) }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(timeout))
                    throw CUAError(code: .timeout, message: "\(method.rawValue) exceeded \(timeout)ms")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            response = RPCResponse(id: request.id, result: result)
        } catch let error as CUAError {
            response = RPCResponse(id: request.id, error: error)
        } catch is CancellationError {
            response = RPCResponse(id: request.id, error: CUAError(code: .timeout, message: "Request cancelled"))
        } catch {
            log.error("method=\(request.method) internal error: \(error)")
            response = RPCResponse(id: request.id, error: CUAError(code: .internalError, message: "Internal service error"))
        }
        log.info("method=\(request.method) elapsed=\(start.duration(to: .now)) code=\(response.error?.code ?? 0)")
        // 合法通知不返回响应；版本不合法的消息仍返回 invalidRequest。
        return request.id == nil && request.jsonrpc == "2.0" ? nil : response
    }

    private func decode<T: Decodable>(_ type: T.Type, _ params: JSONValue?, _ method: CUAMethod) throws -> T {
        do { return try CUACodec.decode(type, from: params ?? .object([:])) }
        catch { throw CUAError.invalidParams("Cannot decode parameters: \(error)", method: method.rawValue) }
    }
    private func authorize(_ params: JSONValue?, app: String?) async throws {
        if let app { try await sessions.checkAuthorization(sessionId: params?["sessionId"]?.stringValue, app: app) }
        else { _ = try await sessions.requireSession(params?["sessionId"]?.stringValue) }
    }
    private func action<T: Decodable & Sendable>(_ type: T.Type, _ method: CUAMethod, _ params: JSONValue?,
                                               body: @Sendable (T) async throws -> Void) async throws -> JSONValue {
        let value = try decode(type, params, method)
        try await authorize(params, app: params?["app"]?.stringValue)
        try await gate.check(accessibility: true)
        try Task.checkCancellation()
        try await body(value)
        return .object([:])
    }
    private func dispatch(_ method: CUAMethod, params: JSONValue?) async throws -> JSONValue {
        switch method {
        case .ping:
            _ = try decode(PingParams.self, params, method)
            if let id = params?["sessionId"], id.stringValue == nil {
                throw CUAError.invalidParams("sessionId must be a string", method: method.rawValue)
            }
            let session = try await sessions.ping(sessionId: params?["sessionId"]?.stringValue)
            let info = CUAServerInfo(serverVersion: CUAProtocolVersion.serviceVersion,
                                     apiVersion: CUAProtocolVersion.current,
                                     features: CUAMethod.allCases.map(\.rawValue), permissions: await engine.permissions())
            var result = try CUACodec.jsonValue(info).objectValue ?? [:]
            result["sessionId"] = .string(session.id)
            return .object(result)
        case .getPermissions:
            return try CUACodec.jsonValue(await engine.permissions())
        case .listApps:
            let value = try decode(ListAppsParams.self, params, method)
            return try CUACodec.jsonValue(ListAppsResult(apps: try await engine.listApps(includeWindows: value.includeWindows ?? false)))
        case .listWindows:
            return try CUACodec.jsonValue(ListWindowsResult(windows: try await engine.listWindows()))
        case .getAppState:
            let value = try decode(GetAppStateParams.self, params, method)
            try await authorize(params, app: value.app)
            try await gate.check(accessibility: value.includeText ?? true, screenRecording: value.includeScreenshot ?? true)
            try Task.checkCancellation()
            return try CUACodec.jsonValue(GetAppStateResult(state: try await engine.getAppState(value)))
        case .click: return try await action(ClickParams.self, method, params) { try await self.engine.click($0) }
        case .pressKey: return try await action(PressKeyParams.self, method, params) { try await self.engine.pressKey($0) }
        case .typeText: return try await action(TypeTextParams.self, method, params) { try await self.engine.typeText($0) }
        case .scroll: return try await action(ScrollParams.self, method, params) { try await self.engine.scroll($0) }
        case .setValue: return try await action(SetValueParams.self, method, params) { try await self.engine.setValue($0) }
        case .drag: return try await action(DragParams.self, method, params) { try await self.engine.drag($0) }
        case .paste: return try await action(PasteParams.self, method, params) { try await self.engine.paste($0) }
        case .selectText: return try await action(SelectTextParams.self, method, params) { try await self.engine.selectText($0) }
        case .performSecondaryAction: return try await action(PerformSecondaryActionParams.self, method, params) { try await self.engine.performSecondaryAction($0) }
        case .captureScreenshot:
            let value = try decode(CaptureScreenshotParams.self, params, method)
            try await authorize(params, app: value.app)
            try await gate.check(screenRecording: true)
            try Task.checkCancellation()
            return try CUACodec.jsonValue(CaptureScreenshotResult(screenshots: try await engine.captureScreenshot(value)))
        case .endSession:
            let value = try decode(EndSessionParams.self, params, method)
            try await sessions.endSession(value.sessionId)
            await engine.resetSessionState()
            return .object([:])
        }
    }
}
