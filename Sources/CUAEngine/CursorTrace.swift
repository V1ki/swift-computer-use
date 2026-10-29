import AppKit
import ApplicationServices
import CUACore
import os

/// Per-action, task-local diagnostics. Never logs text, key contents, or AX values.
/// Enable in the SERVICE environment (not just the CLI): SWIFTCUA_TRACE_CURSOR=1.
final class CursorTrace: @unchecked Sendable {
    private static let logger = Logger(subsystem: CUALog.subsystem, category: "cursor")
    private let lock = NSLock()
    private var globalPosts = 0
    private var targetedPosts = 0
    private let id = UUID().uuidString
    private let action: String
    private let enabled: Bool
    let allowActivation: Bool

    init(action: String, allowActivation: Bool) {
        self.action = action
        self.allowActivation = allowActivation
        enabled = ProcessInfo.processInfo.environment["SWIFTCUA_TRACE_CURSOR"] == "1"
    }

    func posted(global: Bool) {
        lock.lock()
        if global { globalPosts += 1 } else { targetedPosts += 1 }
        lock.unlock()
        record(global ? "global-post" : "pid-post")
    }

    func record(_ phase: String) {
        guard enabled else { return }
        let location = CGEvent(source: nil)?.location
        let front = NSWorkspace.shared.frontmostApplication
        lock.lock()
        let global = globalPosts, targeted = targetedPosts
        lock.unlock()
        let text = "cursor action=\(action) id=\(id) phase=\(phase) servicePID=\(getpid()) allowActivation=\(allowActivation) location=\(location.map { "\($0.x),\($0.y)" } ?? "unavailable") frontmost=\(front?.bundleIdentifier ?? "unknown") frontPID=\(front?.processIdentifier ?? -1) globalCGEvent=\(global > 0) globalPosts=\(global) pidPosts=\(targeted)"
        // Notice persists in the unified log without enabling debug/info storage.
        Self.logger.notice("\(text, privacy: .public)")
    }
}

/// All Quartz injection passes this seam. Tests replace it; they never post input.
protocol EventPoster: Sendable {
    func postGlobal(_ event: CGEvent)
    func post(_ event: CGEvent, to pid: pid_t)
}

struct QuartzEventPoster: EventPoster {
    func postGlobal(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
    func post(_ event: CGEvent, to pid: pid_t) { event.postToPid(pid) }
}

struct InputContext: Sendable {
    let allowActivation: Bool
    let poster: any EventPoster
    let trace: CursorTrace?

    init(allowActivation: Bool = false, poster: any EventPoster = QuartzEventPoster(), trace: CursorTrace? = nil) {
        self.allowActivation = allowActivation
        self.poster = poster
        self.trace = trace
    }
}
