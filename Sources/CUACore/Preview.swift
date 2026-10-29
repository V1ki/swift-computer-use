import Foundation

/// A downscaled live frame for the picture-in-picture preview.
public struct CUAPreviewFrame: Sendable {
    public var jpeg: Data
    public var app: String?
    public var windowID: UInt32
    public var timestamp: Date

    public init(jpeg: Data, app: String?, windowID: UInt32, timestamp: Date = Date()) {
        self.jpeg = jpeg
        self.app = app
        self.windowID = windowID
        self.timestamp = timestamp
    }
}

/// Decouples the engine (which produces frames) from the service UI (which draws
/// them). Frames are pre-encoded JPEG thumbnails so nothing non-Sendable crosses
/// an isolation boundary.
public actor PreviewHub {
    public static let shared = PreviewHub()

    private var observers: [UUID: @Sendable (CUAPreviewFrame) -> Void] = [:]

    public func subscribe(_ observer: @escaping @Sendable (CUAPreviewFrame) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    public func unsubscribe(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    public func publish(_ frame: CUAPreviewFrame) {
        for observer in observers.values { observer(frame) }
    }

    public var hasObservers: Bool { !observers.isEmpty }
}
