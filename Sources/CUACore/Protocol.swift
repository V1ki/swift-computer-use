import Foundation

// MARK: - JSON-RPC envelope

/// Identifiers are integers or strings per JSON-RPC 2.0.
public enum RPCID: Codable, Sendable, Hashable {
    case int(Int64)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if container.decodeNil() {
            self = .string("")
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RPC id must be an integer or string"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// A JSON-RPC request as it travels on the wire. Params stay type-erased so the
/// router can decode them per method.
public struct RPCRequest: Codable, Sendable {
    public var jsonrpc: String
    public var id: RPCID?
    public var method: String
    public var params: JSONValue?

    public init(id: RPCID? = nil, method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC response. Exactly one of `result` / `error` is present.
public struct RPCResponse: Codable, Sendable {
    public var jsonrpc: String
    public var id: RPCID?
    public var result: JSONValue?
    public var error: RPCErrorPayload?

    public init(id: RPCID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RPCID?, error: CUAError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = RPCErrorPayload(error: error)
    }
}

public struct RPCErrorPayload: Codable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(error: CUAError) {
        self.code = error.code.rawValue
        self.message = error.message
        self.data = error.data
    }
}

// MARK: - Method surface

/// The method names on the SwiftCUA wire. These mirror the mac target of the
/// original `sky` client closely enough that a JS bridge can expose an
/// identical `sky` object.
public enum CUAMethod: String, Codable, Sendable, CaseIterable {
    case ping
    case getPermissions
    case listApps
    case listWindows
    case getAppState
    case click
    case pressKey
    case typeText
    case scroll
    case setValue
    case drag
    case paste
    case selectText
    case performSecondaryAction
    case captureScreenshot
    case findText
    case clickText
    case searchText
    case openChat
    case readChat
    case sendText
    case setOptions
    case endSession

    /// Notifications are fire-and-forget and carry no id.
    public var isNotificationOnly: Bool { self == .endSession }
}

// MARK: - Versioning

public enum CUAProtocolVersion {
    /// Mirrors the original handshake style (`CodexComputerUseIPC-5`).
    public static let current = "SwiftCUA-IPC-1"
    public static let serviceVersion = "0.1.0"
}

// MARK: - Typed params

public struct PingParams: Codable, Sendable, Hashable {
    public var clientApiVersion: String
    public var clientName: String?
    public var clientVersion: String?
    public var pid: Int32?

    public init(
        clientApiVersion: String,
        clientName: String? = nil,
        clientVersion: String? = nil,
        pid: Int32? = nil
    ) {
        self.clientApiVersion = clientApiVersion
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.pid = pid
    }
}

public struct ListAppsParams: Codable, Sendable, Hashable {
    public var includeWindows: Bool?
    public var sessionId: String?

    public init(includeWindows: Bool? = nil, sessionId: String? = nil) {
        self.includeWindows = includeWindows
        self.sessionId = sessionId
    }
}

public struct ListAppsResult: Codable, Sendable, Hashable {
    public var apps: [CUAAppInfo]
    public init(apps: [CUAAppInfo]) { self.apps = apps }
}

public struct ListWindowsResult: Codable, Sendable, Hashable {
    public var windows: [CUAWindowInfo]
    public init(windows: [CUAWindowInfo]) { self.windows = windows }
}

public struct GetAppStateParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    /// Capture a bounded screenshot of the app window. Defaults to true.
    public var includeScreenshot: Bool?
    /// Capture accessibility text. Defaults to true.
    public var includeText: Bool?
    /// Return the full tree instead of a diff from the previous capture.
    public var disableDiff: Bool?
    /// Case-insensitive accessibility tree filter that keeps matching ancestors.
    public var query: String?
    /// Window id to target when the app owns several windows.
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        includeScreenshot: Bool? = nil,
        includeText: Bool? = nil,
        disableDiff: Bool? = nil,
        query: String? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.includeScreenshot = includeScreenshot
        self.includeText = includeText
        self.disableDiff = disableDiff
        self.query = query
        self.windowId = windowId
    }
}

public struct GetAppStateResult: Codable, Sendable, Hashable {
    public var state: CUAAppState
    public init(state: CUAAppState) { self.state = state }
}

public struct ClickParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var elementIndex: Int?
    /// Window-relative coordinates inside the target app window.
    public var x: Double?
    public var y: Double?
    public var clickCount: Int?
    public var mouseButton: String?
    /// Key chord held during the click, e.g. `Control_L+a`.
    public var key: String?
    public var durationMilliseconds: Int?
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        clickCount: Int? = nil,
        mouseButton: String? = nil,
        key: String? = nil,
        durationMilliseconds: Int? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.elementIndex = elementIndex
        self.x = x
        self.y = y
        self.clickCount = clickCount
        self.mouseButton = mouseButton
        self.key = key
        self.durationMilliseconds = durationMilliseconds
        self.windowId = windowId
    }
}

public struct PressKeyParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var key: String
    public var durationMilliseconds: Int?
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        key: String,
        durationMilliseconds: Int? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.key = key
        self.durationMilliseconds = durationMilliseconds
        self.windowId = windowId
    }
}

public struct TypeTextParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var text: String
    public var elementIndex: Int?
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        text: String,
        elementIndex: Int? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.text = text
        self.elementIndex = elementIndex
        self.windowId = windowId
    }
}

public struct ScrollParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var direction: String?
    public var elementIndex: Int?
    public var x: Double?
    public var y: Double?
    public var pages: Double?
    public var pixels: Double?
    /// Raw deltas, used by the window-level API. Negative is up/left.
    public var scrollX: Double?
    public var scrollY: Double?
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        direction: String? = nil,
        elementIndex: Int? = nil,
        x: Double? = nil,
        y: Double? = nil,
        pages: Double? = nil,
        pixels: Double? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.direction = direction
        self.elementIndex = elementIndex
        self.x = x
        self.y = y
        self.pages = pages
        self.pixels = pixels
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.windowId = windowId
    }
}

public struct SetValueParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var elementIndex: Int
    public var value: String
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        elementIndex: Int,
        value: String,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.elementIndex = elementIndex
        self.value = value
        self.windowId = windowId
    }
}

public struct DragParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var fromX: Double
    public var fromY: Double
    public var toX: Double
    public var toY: Double
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.fromX = fromX
        self.fromY = fromY
        self.toX = toX
        self.toY = toY
        self.windowId = windowId
    }
}

public struct PasteParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var text: String
    public var format: String?
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        text: String,
        format: String? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.text = text
        self.format = format
        self.windowId = windowId
    }
}

public struct SelectTextParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var elementIndex: Int
    public var text: String
    public var prefix: String?
    public var suffix: String?
    public var selectionType: String?
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        elementIndex: Int,
        text: String,
        prefix: String? = nil,
        suffix: String? = nil,
        selectionType: String? = nil,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.elementIndex = elementIndex
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.selectionType = selectionType
        self.windowId = windowId
    }
}

public struct PerformSecondaryActionParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var elementIndex: Int
    public var action: String
    public var windowId: UInt32?

    public init(
        app: String,
        sessionId: String? = nil,
        elementIndex: Int,
        action: String,
        windowId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.elementIndex = elementIndex
        self.action = action
        self.windowId = windowId
    }
}

public struct CaptureScreenshotParams: Codable, Sendable, Hashable {
    public var app: String?
    public var sessionId: String?
    public var windowId: UInt32?
    public var displayId: UInt32?

    public init(
        app: String? = nil,
        sessionId: String? = nil,
        windowId: UInt32? = nil,
        displayId: UInt32? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.windowId = windowId
        self.displayId = displayId
    }
}

public struct CaptureScreenshotResult: Codable, Sendable, Hashable {
    public var screenshots: [CUAScreenshot]
    public init(screenshots: [CUAScreenshot]) { self.screenshots = screenshots }
}

public struct EndSessionParams: Codable, Sendable, Hashable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: - Codec

public enum CUACodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// Converts an encodable value into a `JSONValue` for envelope embedding.
    public static func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try makeEncoder().encode(value)
        return try makeDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes a `JSONValue` into a typed parameter model.
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue?) throws -> T {
        guard let value else {
            throw CUAError(code: .invalidParams, message: "Missing params")
        }
        let data = try makeEncoder().encode(value)
        return try makeDecoder().decode(T.self, from: data)
    }
}

// MARK: - Text location params

public struct FindTextParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    /// Substring to look for; case-insensitive unless `exact` is true.
    public var text: String
    public var exact: Bool?
    /// Allow falling back to on-screen OCR when the AX tree has no match.
    public var useOCR: Bool?
    /// Skip the AX lookup entirely and locate by OCR (useful to verify the
    /// pixel path, or when the AX tree exists but is known to be wrong).
    public var ocrOnly: Bool?
    public var windowId: UInt32?
    public var limit: Int?

    public init(
        app: String,
        sessionId: String? = nil,
        text: String,
        exact: Bool? = nil,
        useOCR: Bool? = nil,
        ocrOnly: Bool? = nil,
        windowId: UInt32? = nil,
        limit: Int? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.text = text
        self.exact = exact
        self.useOCR = useOCR
        self.ocrOnly = ocrOnly
        self.windowId = windowId
        self.limit = limit
    }
}

public struct FindTextResult: Codable, Sendable, Hashable {
    public var matches: [CUATextMatch]
    public init(matches: [CUATextMatch]) { self.matches = matches }
}

public struct ClickTextParams: Codable, Sendable, Hashable {
    public var app: String
    public var sessionId: String?
    public var text: String
    public var exact: Bool?
    public var useOCR: Bool?
    public var ocrOnly: Bool?
    public var windowId: UInt32?
    public var clickCount: Int?

    public init(
        app: String,
        sessionId: String? = nil,
        text: String,
        exact: Bool? = nil,
        useOCR: Bool? = nil,
        ocrOnly: Bool? = nil,
        windowId: UInt32? = nil,
        clickCount: Int? = nil
    ) {
        self.app = app
        self.sessionId = sessionId
        self.text = text
        self.exact = exact
        self.useOCR = useOCR
        self.ocrOnly = ocrOnly
        self.windowId = windowId
        self.clickCount = clickCount
    }
}

public struct ClickTextResult: Codable, Sendable, Hashable {
    public var match: CUATextMatch
    public init(match: CUATextMatch) { self.match = match }
}

// MARK: - Runtime options

/// Per-connection/service automation policy.
/// `activate == true` restores focus-stealing behaviour (raise + real cursor);
/// default is fully background (AX + pid-targeted events only).
public struct SetOptionsParams: Codable, Sendable, Hashable {
    public var activate: Bool?

    public init(activate: Bool? = nil) {
        self.activate = activate
    }
}
