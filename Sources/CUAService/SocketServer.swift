import Foundation
import Dispatch
import Darwin
import CUACore

private func socketError(_ operation: String) -> CUAError {
    CUAError(code: .internalError, message: "\(operation): \(String(cString: strerror(errno)))")
}

/// sockaddr_un 的长度包含结尾 NUL，提前拒绝超出 Darwin 路径上限的地址。
func withUnixAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path), !path.utf8.contains(0) else {
        throw CUAError(code: .invalidParams, message: "Unix socket path is too long or contains NUL")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// 所有可变描述符状态由锁保护；每条连接只运行一条串行读写流水线。
final class SocketServer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "swiftcua.accept")
    private let router: RequestRouter
    private let validator: PeerValidator
    private let idleTimeout: TimeInterval
    let socketPath: String
    private let lockPath: String
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private var connections: [UUID: SocketConnection] = [:]
    private var ownsSocket = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private let readyHandler: @Sendable (String) -> Void

    init(socketPath: String = CUAPaths.socketPath.path, router: RequestRouter,
         validator: PeerValidator = PeerValidator(configuration: ServiceConfiguration()),
         idleTimeout: TimeInterval = 300, readyHandler: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.lockPath = socketPath + ".lock"
        self.router = router
        self.validator = validator
        self.idleTimeout = idleTimeout
        self.readyHandler = readyHandler
    }
    deinit { stop() }

    func start(installSignalHandlers: Bool = false) throws {
        try lock.withLock {
            guard listener < 0 else { throw CUAError(code: .internalError, message: "Server already started") }
            try CUAPaths.ensureDirectories()
            let parent = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw socketError("open lock") }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(fd)
                throw CUAError(code: .internalError, message: "Another SwiftCUA instance holds the socket lock")
            }
            // 删除锁文件和下次启动之间存在路径竞争，确认持有的仍是路径对应的 inode。
            var held = stat(), current = stat()
            guard fstat(fd, &held) == 0, lstat(lockPath, &current) == 0,
                  held.st_ino == current.st_ino, held.st_dev == current.st_dev else {
                Darwin.close(fd)
                throw CUAError(code: .internalError, message: "Socket lock changed during startup; retry")
            }
            lockFD = fd
            do {
                var existing = stat()
                if lstat(socketPath, &existing) == 0 {
                    guard (existing.st_mode & S_IFMT) == S_IFSOCK else {
                        throw CUAError(code: .internalError, message: "Refusing to remove a non-socket path")
                    }
                    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                    guard probe >= 0 else { throw socketError("probe socket") }
                    _ = fcntl(probe, F_SETFL, O_NONBLOCK)
                    let connected: Bool
                    do { connected = try withUnixAddress(socketPath) { Darwin.connect(probe, $0, $1) == 0 } }
                    catch { Darwin.close(probe); throw error }
                    let probeError = errno
                    Darwin.close(probe)
                    if connected || probeError == EINPROGRESS || probeError == EAGAIN {
                        throw CUAError(code: .internalError, message: "Another SwiftCUA instance is listening")
                    }
                    guard probeError == ECONNREFUSED || probeError == ENOENT else { throw socketError("probe existing socket") }
                    guard unlink(socketPath) == 0 || errno == ENOENT else { throw socketError("unlink stale socket") }
                }
                listener = socket(AF_UNIX, SOCK_STREAM, 0)
                guard listener >= 0 else { throw socketError("socket") }
                _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
                guard try withUnixAddress(socketPath, { Darwin.bind(listener, $0, $1) }) == 0 else { throw socketError("bind") }
                ownsSocket = true
                guard chmod(socketPath, 0o600) == 0 else { throw socketError("chmod") }
                guard listen(listener, 16) == 0 else { throw socketError("listen") }
                guard fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw socketError("nonblocking listen") }
                let listeningFD = listener
                let readSource = DispatchSource.makeReadSource(fileDescriptor: listeningFD, queue: queue)
                readSource.setEventHandler { [weak self] in self?.acceptAvailable() }
                readSource.setCancelHandler { Darwin.close(listeningFD) }
                source = readSource
                readSource.resume()
                if installSignalHandlers {
                    for number in [SIGINT, SIGTERM] {
                        signal(number, SIG_IGN)
                        let signalSource = DispatchSource.makeSignalSource(signal: number, queue: queue)
                        signalSource.setEventHandler { [weak self] in self?.stop() }
                        signals.append(signalSource)
                        signalSource.resume()
                    }
                }
            } catch {
                cleanupLocked()
                throw error
            }
        }
        FileHandle.standardError.write(Data("listening on \(socketPath)\n".utf8))
        readyHandler(socketPath)
    }
    var isRunning: Bool { lock.withLock { listener >= 0 } }
    func stop() { lock.withLock { cleanupLocked() } }
    func waitUntilStopped() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if listener < 0 { continuation.resume() }
                else { stopWaiters.append(continuation) }
            }
        }
    }
    private func cleanupLocked() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
        for signal in signals { signal.cancel() }
        signals.removeAll()
        if let source { source.cancel(); self.source = nil }
        else if listener >= 0 { Darwin.close(listener) }
        listener = -1
        for waiter in stopWaiters { waiter.resume() }
        stopWaiters.removeAll()
        if ownsSocket { _ = unlink(socketPath); ownsSocket = false }
        if lockFD >= 0 {
            _ = unlink(lockPath)
            _ = flock(lockFD, LOCK_UN)
            Darwin.close(lockFD)
            lockFD = -1
        }
    }
    private func acceptAvailable() {
        while true {
            let fd: Int32 = lock.withLock {
                guard listener >= 0 else { return -1 }
                return Darwin.accept(listener, nil, nil)
            }
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            // Darwin 可能继承监听器的非阻塞标志，连接读循环使用独立队列上的阻塞 I/O。
            _ = fcntl(fd, F_SETFL, 0)
            guard validator.validate(fd: fd) else { Darwin.close(fd); continue }
            let id = UUID()
            let connection = SocketConnection(fd: fd, idleTimeout: idleTimeout, router: router)
            let accepted = lock.withLock {
                guard listener >= 0 else { return false }
                connections[id] = connection
                return true
            }
            guard accepted else { connection.stop(); continue }
            connection.start { [weak self] in self?.removeConnection(id) }
        }
    }
    private func removeConnection(_ id: UUID) { _ = lock.withLock { connections.removeValue(forKey: id) } }
}

private final class SocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let router: RequestRouter
    private let queue = DispatchQueue(label: "swiftcua.connection")
    private let lock = NSLock()
    private var stopped = false
    private var closed = false
    private var task: Task<Void, Never>?
    func start(onFinish: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard !stopped, !closed else { return }
            task = Task {
                await self.run()
                onFinish()
            }
        }
    }
    init(fd: Int32, idleTimeout: TimeInterval, router: RequestRouter) {
        self.fd = fd
        self.router = router
        let seconds = max(0.001, idleTimeout)
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { finish() }
    func stop() {
        lock.withLock {
            guard !stopped, !closed else { return }
            stopped = true
            task?.cancel()
            _ = shutdown(fd, SHUT_RDWR)
        }
    }
    private func finish() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            task = nil
            Darwin.close(fd)
        }
    }
    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                var count: Int
                repeat { count = Darwin.recv(self.fd, &buffer, buffer.count, 0) } while count < 0 && errno == EINTR
                continuation.resume(returning: count > 0 ? Data(buffer.prefix(count)) : nil)
            }
        }
    }
    private func send(_ response: RPCResponse) async -> Bool {
        guard var envelope = try? CUACodec.jsonValue(response).objectValue else { return false }
        // Core 的可选 id 在编码时省略；传输错误必须显式回传 JSON null。
        if response.id == nil { envelope["id"] = .null }
        guard let payload = try? CUACodec.encode(JSONValue.object(envelope)), payload.count <= CUAFraming.maxMessageBytes else { return false }
        let frame = CUAFraming.encode(payload)
        return await withCheckedContinuation { continuation in
            queue.async {
                let success = frame.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.send(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                        if count < 0 && errno == EINTR { continue }
                        if count <= 0 { return false }
                        offset += count
                    }
                    return true
                }
                continuation.resume(returning: success)
            }
        }
    }
    func run() async {
        defer { finish() }
        var decoder = CUAStreamDecoder(maxMessageBytes: 8 * 1024 * 1024)
        while let bytes = await receive() {
            do {
                for payload in try decoder.append(bytes) {
                    if lock.withLock({ stopped }) { return }
                    if let response = await router.handle(payload), !(await send(response)) { return }
                }
            } catch {
                let error = error as? CUAError ?? CUAError(code: .invalidRequest, message: "Invalid frame")
                _ = await send(RPCResponse(id: nil, error: error))
                return
            }
        }
    }
}
