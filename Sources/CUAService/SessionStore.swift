import Foundation
import CUACore

actor SessionStore {
    struct Session: Sendable {
        let id: String
        var allowedApps: Set<String>
        let createdAt: Date
        var lastSeen: Date
    }
    struct PendingAuthorization: Sendable, Hashable {
        let sessionId: String
        let app: String
    }
    private var sessions: [String: Session] = [:]
    private(set) var pending: Set<PendingAuthorization> = []
    private let directory: URL
    private let autoAuthorizeApps: Bool
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private var cleanupTask: Task<Void, Never>?

    init(directory: URL = CUAPaths.sessionsDirectory, autoAuthorizeApps: Bool = true,
         ttl: TimeInterval = 86400, now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.directory = directory
        self.autoAuthorizeApps = autoAuthorizeApps
        self.ttl = ttl
        self.now = now
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    deinit { cleanupTask?.cancel() }

    func startCleanup(interval: Duration = .seconds(600)) {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.removeExpired()
            }
        }
    }
    func stopCleanup() { cleanupTask?.cancel(); cleanupTask = nil }

    /// 只允许单个安全文件名，避免客户端会话标识穿越目录。
    private func fileURL(_ id: String) throws -> URL {
        guard !id.isEmpty, id.utf8.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
            throw CUAError.invalidParams("Invalid sessionId", method: "session")
        }
        return directory.appendingPathComponent(id + ".toml")
    }
    private func load(_ id: String) throws -> Session? {
        if let value = sessions[id] { return value }
        let url = try fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let text = try String(contentsOf: url, encoding: .utf8)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let date = attrs[.modificationDate] as? Date ?? now()
        // 允许列表是固定 TOML 子集，字符串数组同时遵循 JSON 的转义语法。
        var inApps = false
        var apps: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inApps = line == "[apps]" }
            if inApps, let equals = line.firstIndex(of: "="),
               line[..<equals].trimmingCharacters(in: .whitespaces) == "allowed" {
                let array = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                apps = try CUACodec.decode([String].self, from: Data(array.utf8))
            }
        }
        let value = Session(id: id, allowedApps: Set(apps), createdAt: attrs[.creationDate] as? Date ?? date, lastSeen: date)
        sessions[id] = value
        return value
    }
    private func persist(_ session: Session) throws {
        let url = try fileURL(session.id)
        let array = String(decoding: try CUACodec.encode(session.allowedApps.sorted()), as: UTF8.self)
        try Data("[apps]\nallowed = \(array)\n".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: session.lastSeen], ofItemAtPath: url.path)
        sessions[session.id] = session
    }
    func ping(sessionId: String?) throws -> Session {
        let id = sessionId ?? UUID().uuidString
        _ = try fileURL(id)
        let current = now()
        var value = try load(id)
        if let old = value, current.timeIntervalSince(old.lastSeen) >= ttl {
            try endSession(id)
            value = nil
        }
        var session = value ?? Session(id: id, allowedApps: [], createdAt: current, lastSeen: current)
        session.lastSeen = current
        try persist(session)
        return session
    }
    func requireSession(_ id: String?) throws -> Session {
        guard let id, var session = try load(id) else {
            throw CUAError(code: .sessionNotFound, message: "Call ping with a sessionId before targeting an app")
        }
        guard now().timeIntervalSince(session.lastSeen) < ttl else {
            try endSession(id)
            throw CUAError(code: .sessionNotFound, message: "Session expired")
        }
        session.lastSeen = now()
        try persist(session)
        return session
    }
    func checkAuthorization(sessionId: String?, app: String) throws {
        let session = try requireSession(sessionId)
        if session.allowedApps.contains(app) { return }
        if autoAuthorizeApps { try authorizeApp(sessionId: session.id, app: app) }
        else {
            pending.insert(PendingAuthorization(sessionId: session.id, app: app))
            throw CUAError.appNotAuthorized(app)
        }
    }
    func authorizeApp(sessionId: String, app: String) throws {
        var session = try requireSession(sessionId)
        session.allowedApps.insert(app)
        try persist(session)
        pending.remove(PendingAuthorization(sessionId: sessionId, app: app))
    }
    func endSession(_ id: String) throws {
        let url = try fileURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        sessions.removeValue(forKey: id)
        pending = pending.filter { $0.sessionId != id }
    }
    func removeExpired() {
        // 同时扫描尚未载入内存的历史会话文件。
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "toml" {
            let id = file.deletingPathExtension().lastPathComponent
            do {
                if let session = try load(id), now().timeIntervalSince(session.lastSeen) >= ttl { try endSession(id) }
            } catch { CUALogger(CUALog.service).warning("Session cleanup failed: \(error)") }
        }
    }
}
