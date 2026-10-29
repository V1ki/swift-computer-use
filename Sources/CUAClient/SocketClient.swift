import Foundation
import Darwin
import CUACore

/// 错误保留服务端原始错误码，便于 CLI 与 MCP 输出一致的修复提示。
struct ClientError: Error, LocalizedError, Sendable {
    let code: Int
    let message: String
    var errorDescription: String? { "[\(code)] \(message)" }
}

enum ClientDiagnostics {
    static let permissionHelp = "System Settings → Privacy & Security → Screen Recording / Accessibility; enable cua-service, then restart it.\nScreen Recording: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture\nAccessibility: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    static func describe(_ error: any Error) -> String {
        let code: Int
        let message: String
        if let error = error as? ClientError {
            code = error.code; message = error.message
        } else if let error = error as? CUAError {
            code = error.code.rawValue; message = error.message
        } else {
            code = CUAErrorCode.internalError.rawValue; message = error.localizedDescription
        }
        var result = "[\(code)] \(message)"
        switch code {
        case CUAErrorCode.permissionMissing.rawValue: result += "\n" + permissionHelp
        case CUAErrorCode.elementIndexStale.rawValue, CUAErrorCode.elementNotFound.rawValue:
            result += "\nRun cua state --app <id> again to refresh element indices."
        case CUAErrorCode.appNotAuthorized.rawValue:
            result += "\nAuthorize this app in the service session configuration."
        case CUAErrorCode.invalidParams.rawValue: result += "\nSee cua help for arguments."
        default: break
        }
        return result
    }

    static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// 串行队列独占描述符和解帧器；阻塞的 poll 不占用 Swift 协作线程池。
/// 每次请求使用统一截止时间，超时后断开连接，避免迟到响应污染后续请求。
final class SocketClient: @unchecked Sendable {
    let socketPath: String
    let timeout: TimeInterval
    private let queue = DispatchQueue(label: "dev.swiftcua.client.socket")
    private var fd: Int32 = -1
    private var decoder = CUAStreamDecoder()
    private var handshaken = false
    private var sessionId: String?
    private let warning: @Sendable (String) -> Void

    init(socketPath: String? = nil, timeout: TimeInterval = 30,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         warning: @escaping @Sendable (String) -> Void = { ClientDiagnostics.stderr($0) }) {
        let override = environment["SWIFTCUA_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        self.socketPath = ((socketPath ?? override ?? CUAPaths.socketPath.path) as NSString).expandingTildeInPath
        self.timeout = timeout
        self.warning = warning
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    func send(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.timeout.isFinite, self.timeout > 0 else {
                        throw ClientError(code: -32602, message: "--timeout must be a positive finite number of seconds")
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + self.timeout
                    try self.connect(deadline: deadline)
                    if !self.handshaken && method != CUAMethod.ping.rawValue {
                        var handshake = self.pingParams.objectValue ?? [:]
                        if let explicit = params?["sessionId"] { handshake["sessionId"] = explicit }
                        _ = try self.exchange(method: "ping", params: .object(handshake), deadline: deadline)
                    }
                    var outgoing = method == "ping" ? (params ?? self.pingParams) : params
                    // 服务握手分配会话；仅为已知且支持会话的方法补齐，不改变 call 的未知方法。
                    let sessionMethods: Set<String> = ["listApps", "getAppState", "click", "pressKey", "typeText", "scroll", "setValue", "drag", "paste", "selectText", "performSecondaryAction", "captureScreenshot", "findText", "clickText", "axGet", "axSet", "axAction", "axFocus", "axAttributes", "axActions"]
                    if sessionMethods.contains(method), let sessionId = self.sessionId,
                       outgoing == nil || outgoing?.objectValue != nil {
                        var object = outgoing?.objectValue ?? [:]
                        if object["sessionId"] == nil { object["sessionId"] = .string(sessionId) }
                        outgoing = .object(object)
                    }
                    let result = try self.exchange(method: method, params: outgoing, deadline: deadline)
                    continuation.resume(returning: result)
                } catch {
                    self.disconnect()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func send(method: CUAMethod, params: JSONValue? = nil) async throws -> JSONValue {
        try await send(method: method.rawValue, params: params)
    }

    func endSession(_ sessionId: String) async throws {
        _ = try await send(method: .endSession, params: .object(["sessionId": .string(sessionId)]))
    }

    private var pingParams: JSONValue {
        .object(["clientApiVersion": .string(CUAProtocolVersion.current), "clientName": "cua",
                 "clientVersion": .string(CUAProtocolVersion.serviceVersion), "pid": .int(Int(getpid()))])
    }

    static func versionMatches(_ result: JSONValue) -> Bool {
        let server = result["server"] ?? result
        return server["apiVersion"]?.stringValue?.hasPrefix(CUAProtocolVersion.current) == true
    }

    private func disconnect() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1; handshaken = false; sessionId = nil; decoder = CUAStreamDecoder()
    }

    private func connect(deadline: TimeInterval) throws {
        guard fd < 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path), !socketPath.utf8.contains(0) else {
            throw ClientError(code: -32602, message: "Unix socket path is too long or contains NUL: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw connectionError() }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw connectionError() }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw connectionError() }
            try wait(events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw connectionError(error == 0 ? errno : error)
            }
        }
    }

    private func connectionError(_ number: Int32 = errno) -> ClientError {
        ClientError(code: -32001, message: "service not running; start with: cua-service &\nSocket: \(socketPath) (\(String(cString: strerror(number)))). Check --socket or SWIFTCUA_SOCKET and directory permissions.")
    }

    private func wait(events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw ClientError(code: CUAErrorCode.timeout.rawValue,
                                  message: "Request timed out after \(timeout)s; check service logs or increase --timeout.")
            }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let milliseconds = Int32(min(ceil(remaining * 1000), Double(Int32.max)))
            let result = poll(&item, 1, milliseconds)
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0, item.revents & Int16(POLLNVAL) == 0 else { throw connectionError() }
            // 挂断时仍可能有最后一帧可读，交给 recv 消费。
            if item.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0 { return }
        }
    }

    private func exchange(method: String, params: JSONValue?, deadline: TimeInterval) throws -> JSONValue {
        let notification = method == CUAMethod.endSession.rawValue
        let id: RPCID? = notification ? nil : .string(UUID().uuidString)
        let payload = try CUACodec.encode(RPCRequest(id: id, method: method, params: params))
        guard payload.count <= CUAFraming.maxMessageBytes else {
            throw ClientError(code: -32602, message: "Request exceeds the 8 MiB frame limit")
        }
        let frame = CUAFraming.encode(payload)
        var offset = 0
        while offset < frame.count {
            try wait(events: Int16(POLLOUT), deadline: deadline)
            let count = frame.withUnsafeBytes {
                Darwin.send(fd, $0.baseAddress!.advanced(by: offset), frame.count - offset, 0)
            }
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else { throw connectionError() }
            offset += count
        }
        if notification { return .null }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try wait(events: Int16(POLLIN), deadline: deadline)
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            guard count > 0 else {
                throw ClientError(code: -32002, message: "Service disconnected; inspect service logs and restart with: cua-service &")
            }
            for payload in try decoder.append(Data(buffer.prefix(count))) {
                let response = try CUACodec.decode(RPCResponse.self, from: payload)
                guard response.id == id else { continue }
                // Codable 的可选字段会把显式 null 读成 nil，原始对象用于区分合法 null 结果。
                let envelope = try CUACodec.decode(JSONValue.self, from: payload)
                guard response.jsonrpc == "2.0", (envelope["result"] != nil) != (envelope["error"] != nil) else {
                    throw ClientError(code: -32600, message: "Malformed JSON-RPC response from service")
                }
                if let error = response.error { throw ClientError(code: error.code, message: error.message) }
                let result = response.result ?? .null
                if method == "ping" {
                    handshaken = true
                    sessionId = result["sessionId"]?.stringValue ?? result["server"]?["sessionId"]?.stringValue
                    if !Self.versionMatches(result) {
                        warning("warning: server.apiVersion \((result["server"] ?? result)["apiVersion"]?.stringValue ?? "missing") does not match \(CUAProtocolVersion.current); update cua/service together.")
                    }
                }
                return result
            }
        }
    }
}
