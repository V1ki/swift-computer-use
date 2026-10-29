import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import AppKit
import CUACore

/// Keeps one low-framerate ScreenCaptureKit stream per target window.
///
/// Why a stream instead of one-shot screenshots:
/// - macOS attributes a persistent `SCStream` to the hosting app and shows the
///   system "sharing" indicator / Control Center preview — the same UI the
///   original Codex Computer Use surfaces. One-shot `SCScreenshotManager`
///   captures only flash the sensor indicator briefly.
/// - Subsequent frames are nearly free, so AX/OCR actions during one task do
///   not pay a cold capture each time.
///
/// The manager keeps sessions alive for `idleTimeout` after the last request,
/// so the preview stays visible while an agent is working and disappears when
/// it goes idle.
public actor WindowStream {
    public static let shared = WindowStream()

    private struct PixelFrame: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private struct Session {
        var stream: SCStream
        var latest: CVPixelBuffer?
        var lastUsed: Date
    }

    private var sessions: [UInt32: Session] = [:]
    private var starting: Set<UInt32> = []
    private var cleanupTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 20
    private let queue = DispatchQueue(label: "dev.v1ki.swiftcua.window-stream")

    /// Latest frame for a window, starting a stream if needed.
    /// Returns nil when ScreenCaptureKit cannot share that window; callers then
    /// fall back to `SCScreenshotManager`.
    public func image(windowID: UInt32, timeout: TimeInterval = 2.0) async -> CGImage? {
        if let session = sessions[windowID], let buffer = session.latest {
            sessions[windowID]?.lastUsed = Date()
            scheduleCleanup()
            return Self.makeImage(buffer)
        }
        if sessions[windowID] == nil, !starting.contains(windowID) {
            starting.insert(windowID)
            defer { starting.remove(windowID) }
            do {
                try await start(windowID: windowID)
            } catch {
                CUALogger(CUALog.engine).debug("window stream start failed for \(windowID): \(error)")
                return nil
            }
        }
        // Poll for the first frame with a hard deadline; no continuations to leak.
        let attempts = max(4, Int(timeout * 20))
        for _ in 0..<attempts {
            if let buffer = sessions[windowID]?.latest {
                sessions[windowID]?.lastUsed = Date()
                scheduleCleanup()
                return Self.makeImage(buffer)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        CUALogger(CUALog.engine).debug("window stream produced no frame for \(windowID) within \(timeout)s")
        return nil
    }

    /// Explicit stop (service shutdown / tests).
    public func stopAll() async {
        for (_, session) in sessions {
            try? await session.stream.stopCapture()
        }
        sessions.removeAll()
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    private func start(windowID: UInt32) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CUAError.permissionMissing("ScreenRecording") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CUAError(code: .elementNotFound, message: "Window \(windowID) is not shareable")
        }
        let scale = Self.scale(for: window.frame)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 2 fps
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = StreamOutput { [weak self] buffer in
            let frame = PixelFrame(buffer: buffer)
            Task { await self?.receive(windowID: windowID, frame: frame) }
        }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        sessions[windowID] = Session(stream: stream, latest: nil, lastUsed: Date())
        CUALogger(CUALog.engine).info("capture stream started for window \(windowID)")
        scheduleCleanup()
    }

    private func receive(windowID: UInt32, frame: PixelFrame) {
        guard var session = sessions[windowID] else { return }
        session.latest = frame.buffer
        // Do NOT touch lastUsed here: streaming frames would keep the session
        // alive forever. Idle deadline is refreshed only by actual requests.
        sessions[windowID] = session
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task { [idleTimeout] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let now = Date()
            for (windowID, session) in self.sessions where now.timeIntervalSince(session.lastUsed) > idleTimeout {
                try? await session.stream.stopCapture()
                self.sessions.removeValue(forKey: windowID)
                CUALogger(CUALog.engine).info("capture stream stopped for window \(windowID)")
            }
            if !self.sessions.isEmpty { self.scheduleCleanup() }
        }
    }

    private nonisolated static func scale(for frame: CGRect) -> Double {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 1, &display, &count) != .success || count == 0 {
            return Double(NSScreen.main?.backingScaleFactor ?? 2)
        }
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else {
            return Double(NSScreen.main?.backingScaleFactor ?? 2)
        }
        return max(1, Double(mode.pixelWidth) / Double(mode.width))
    }

    private nonisolated static func makeImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        return context.makeImage()
    }
}

/// Small `SCStreamOutput` shim (delegate protocols are not actor-friendly).
final class StreamOutput: NSObject, SCStreamOutput {
    private let handler: (CVPixelBuffer) -> Void
    init(handler: @escaping (CVPixelBuffer) -> Void) { self.handler = handler }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(buffer)
    }
}
