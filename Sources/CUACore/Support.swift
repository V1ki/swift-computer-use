import Foundation
import os

// MARK: - Filesystem layout

/// Well-known paths shared by the service, the CLI and the JS bridge.
public enum CUAPaths {
    /// Overridable with `SWIFTCUA_HOME`, which keeps tests hermetic.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["SWIFTCUA_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwiftCUA", isDirectory: true)
        return base
    }

    public static var ipcDirectory: URL { home.appendingPathComponent("IPC", isDirectory: true) }
    public static var socketPath: URL { ipcDirectory.appendingPathComponent("computeruse.sock") }
    public static var socketsDirectory: URL { home.appendingPathComponent("Sockets", isDirectory: true) }
    public static var sessionsDirectory: URL { home.appendingPathComponent("sessions", isDirectory: true) }
    public static var logsDirectory: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public static var configPath: URL { home.appendingPathComponent("config.json") }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for directory in [home, ipcDirectory, sessionsDirectory, logsDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }
}

// MARK: - Logging

/// Thin logging facade over `os.Logger` so subsystems show up in Console and
/// `log show` with the same ergonomics as the original service.
public enum CUALog {
    public static let subsystem = "dev.v1ki.swiftcua"

    public static let service = Logger(subsystem: subsystem, category: "service")
    public static let transport = Logger(subsystem: subsystem, category: "transport")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let client = Logger(subsystem: subsystem, category: "client")

    /// Debug logging is compiled in but only emitted when
    /// `SWIFTCUA_DEBUG=1`, which keeps normal runs quiet.
    public static var isDebugEnabled: Bool {
        ProcessInfo.processInfo.environment["SWIFTCUA_DEBUG"] == "1"
    }
}

/// Small value-type wrapper so call sites can do `let log = CUALogger(...)`.
public struct CUALogger: Sendable {
    private let logger: Logger
    private let debugEnabled: Bool

    public init(_ logger: Logger, debugEnabled: Bool = CUALog.isDebugEnabled) {
        self.logger = logger
        self.debugEnabled = debugEnabled
    }

    public func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let text = message()
        logger.debug("\(text, privacy: .public)")
    }

    public func info(_ message: @autoclosure () -> String) {
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    public func warning(_ message: @autoclosure () -> String) {
        let text = message()
        logger.warning("\(text, privacy: .public)")
    }

    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
    }
}
