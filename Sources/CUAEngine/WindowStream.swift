import Foundation
import ScreenCaptureKit
import CoreVideo
import AppKit
import CUACore

/// Keeps one low-framerate ScreenCaptureKit stream per target window.
///
/// Why a stream instead of one-shot screenshots:
/// - macOS attributes a persistent `SCStream` to the hosting app and shows the
///   system "sharing" indicator / Video-menu live preview — the same UI the
///   original Codex Computer Use surfaces. One-shot `SCScreenshotManager`
///   captures only flash the sensor indicator briefly.
/// - Subsequent frames are nearly free, so AX/OCR actions during a task do not
///   pay a cold capture each time.
///
/// Sessions stay alive for `idleTimeout` after the last request so the preview
/// remains visible while an agent works and disappears when it goes idle.
public actor WindowStream {
    public static let shared = WindowStream()

    // MARK: - Sendable boxes
    // ScreenCaptureKit types are not Sendable. They never leave the capture
    // pipeline; boxing is only to satisfy Swift 6 region checks on older
    // toolchains.

    struct PixelFrame: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    /// Owns the stream and its output object so both stay alive together.
    final class StreamBox: @unchecked Sendable {
        let stream: SCStream
        let output: SCStreamOutput

        init(stream: SCStream, output: SCStreamOutput) {
            self.stream = stream
            self.output = output
        }
    }

    struct ShareableWindow: @unchecked Sendable {
        let window: SCWindow
    }

    private struct Session {
        let box: StreamBox
        var latest: CVPixelBuffer?
        var lastUsed: Date
    }

    private var sessions: [UInt32: Session] = [:]
    private var starting: Set<UInt32> = []
    private var labels: [UInt32: String] = [:]
    private var cleanupTask: Task<Void, Never>?
    private let idleTimeout: TimeInterval = 20

    /// Associates a human-readable app label with a window for the preview UI.
    public func setLabel(_ app: String, windowID: UInt32) {
        labels[windowID] = app
    }

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
                let shared = try await Self.shareableWindow(windowID: windowID)
                let box = try await Self.startStream(shared) { [weak self] frame in
                    Task { await self?.receive(windowID: windowID, frame: frame) }
                }
                sessions[windowID] = Session(box: box, latest: nil, lastUsed: Date())
                CUALogger(CUALog.engine).info("capture stream started for window \(windowID)")
                scheduleCleanup()
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
            try? await session.box.stream.stopCapture()
        }
        sessions.removeAll()
        cleanupTask?.cancel()
        cleanupTask = nil
    }

    private func receive(windowID: UInt32, frame: PixelFrame) {
        guard var session = sessions[windowID] else { return }
        session.latest = frame.buffer
        // Do NOT touch lastUsed here: streaming frames would keep the session
        // alive forever. The idle deadline is refreshed only by requests.
        sessions[windowID] = session
        if let jpeg = Self.thumbnailJPEG(frame.buffer) {
            let label = labels[windowID]
            Task { await PreviewHub.shared.publish(CUAPreviewFrame(jpeg: jpeg, app: label, windowID: windowID)) }
        }
    }

    /// Downscales to a preview-sized JPEG (~480px wide); full-res frames are
    /// only used for OCR/screenshots.
    private nonisolated static func thumbnailJPEG(_ buffer: CVPixelBuffer, maxWidth: Int = 480) -> Data? {
        guard let image = makeImage(buffer) else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(image.width))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func scheduleCleanup() {
        cleanupTask?.cancel()
        cleanupTask = Task { [idleTimeout] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let now = Date()
            for (windowID, session) in self.sessions where now.timeIntervalSince(session.lastUsed) > idleTimeout {
                try? await session.box.stream.stopCapture()
                self.sessions.removeValue(forKey: windowID)
                CUALogger(CUALog.engine).info("capture stream stopped for window \(windowID)")
            }
            if !self.sessions.isEmpty { self.scheduleCleanup() }
        }
    }

    // MARK: - Nonisolated ScreenCaptureKit setup

    /// Fetches the SCWindow in a nonisolated helper and returns it through an
    /// @unchecked Sendable box.
    private nonisolated static func shareableWindow(windowID: UInt32) async throws -> ShareableWindow {
        guard CGPreflightScreenCaptureAccess() else { throw CUAError.permissionMissing("ScreenRecording") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CUAError(code: .elementNotFound, message: "Window \(windowID) is not shareable")
        }
        return ShareableWindow(window: window)
    }

    /// Builds, wires and starts the stream entirely off-actor so no
    /// non-Sendable ScreenCaptureKit value crosses an isolation boundary.
    private nonisolated static func startStream(
        _ shared: ShareableWindow,
        handler: @escaping @Sendable (PixelFrame) -> Void
    ) async throws -> StreamBox {
        let window = shared.window
        let scale = scale(for: window.frame)
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 2 fps
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = StreamOutput(handler: handler)
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "dev.v1ki.swiftcua.stream"))
        try await stream.startCapture()
        return StreamBox(stream: stream, output: output)
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
    private let handler: @Sendable (WindowStream.PixelFrame) -> Void

    init(handler: @escaping @Sendable (WindowStream.PixelFrame) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        handler(WindowStream.PixelFrame(buffer: buffer))
    }
}
