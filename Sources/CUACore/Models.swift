import Foundation

// MARK: - Geometry

/// Rectangle in global (display) coordinates, top-left origin, points.
public struct CUARect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Point in global or window-relative coordinates, depending on context.
public struct CUAPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Enumerations

public enum CUAMouseButton: String, Codable, Sendable, CaseIterable {
    case left, right, middle

    /// Accepts the short aliases used by the original client (`l`, `r`, `m`).
    public static func parse(_ raw: String) -> CUAMouseButton? {
        switch raw.lowercased() {
        case "left", "l": return .left
        case "right", "r": return .right
        case "middle", "m": return .middle
        default: return nil
        }
    }
}

public enum CUAScrollDirection: String, Codable, Sendable, CaseIterable {
    case up, down, left, right

    /// Accepts the short aliases used by the original client (`u`, `d`, `l`, `r`).
    public static func parse(_ raw: String) -> CUAScrollDirection? {
        switch raw.lowercased() {
        case "up", "u": return .up
        case "down", "d": return .down
        case "left", "l": return .left
        case "right", "r": return .right
        default: return nil
        }
    }
}

public enum CUASelectionType: String, Codable, Sendable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}

public enum CUAPasteFormat: String, Codable, Sendable {
    case text, md, html
}

// MARK: - Applications and windows

/// One launchable desktop application and the windows it currently owns.
public struct CUAAppInfo: Codable, Sendable, Hashable {
    /// Canonical identifier: bundle identifier, or a process path for non-bundled apps.
    public var id: String
    public var displayName: String?
    public var isRunning: Bool?
    /// ISO 8601 timestamp, when the platform exposes a recency signal.
    public var lastUsedDate: String?
    public var useCount: Int?
    public var windows: [CUAWindowInfo]

    public init(
        id: String,
        displayName: String? = nil,
        isRunning: Bool? = nil,
        lastUsedDate: String? = nil,
        useCount: Int? = nil,
        windows: [CUAWindowInfo] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.isRunning = isRunning
        self.lastUsedDate = lastUsedDate
        self.useCount = useCount
        self.windows = windows
    }
}

/// A mapped, targetable application window.
public struct CUAWindowInfo: Codable, Sendable, Hashable {
    /// Window server identifier (CGWindowID).
    public var id: UInt32
    /// Owning application identifier, matching `CUAAppInfo.id`.
    public var app: String
    public var title: String?
    public var bounds: CUARect
    public var layer: Int
    public var isOnScreen: Bool
    public var isFocused: Bool

    public init(
        id: UInt32,
        app: String,
        title: String? = nil,
        bounds: CUARect,
        layer: Int = 0,
        isOnScreen: Bool = true,
        isFocused: Bool = false
    ) {
        self.id = id
        self.app = app
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.isFocused = isFocused
    }
}

// MARK: - Screenshots

/// A captured screenshot returned as a data URL, mirroring the original wire shape.
public struct CUAScreenshot: Codable, Sendable, Hashable {
    /// Stable identifier within one `getAppState` response.
    public var id: String
    /// `data:image/jpeg;base64,...`
    public var url: String
    public var width: Double?
    public var height: Double?
    /// Screen-space origin of this bounded screenshot region.
    public var originX: Double?
    public var originY: Double?
    /// Relative z-order; larger values are visually above smaller ones.
    public var zIndex: Int
    public var app: String?
    public var windowId: UInt32?

    public init(
        id: String = UUID().uuidString,
        url: String,
        width: Double? = nil,
        height: Double? = nil,
        originX: Double? = nil,
        originY: Double? = nil,
        zIndex: Int = 0,
        app: String? = nil,
        windowId: UInt32? = nil
    ) {
        self.id = id
        self.url = url
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.zIndex = zIndex
        self.app = app
        self.windowId = windowId
    }
}

// MARK: - Accessibility

/// A node of the accessibility tree, flattened with stable per-capture indices.
public struct CUAAccessibilityNode: Codable, Sendable, Hashable {
    /// Index accepted by `click`, `setValue`, `selectText`, `performSecondaryAction`
    /// and `scroll` for this app until the next `getAppState` call.
    public var index: Int
    public var role: String
    public var title: String?
    public var value: String?
    public var description: String?
    public var identifier: String?
    public var states: [String]
    public var actions: [String]
    public var frame: CUARect?
    public var children: [CUAAccessibilityNode]

    public init(
        index: Int,
        role: String,
        title: String? = nil,
        value: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        states: [String] = [],
        actions: [String] = [],
        frame: CUARect? = nil,
        children: [CUAAccessibilityNode] = []
    ) {
        self.index = index
        self.role = role
        self.title = title
        self.value = value
        self.description = description
        self.identifier = identifier
        self.states = states
        self.actions = actions
        self.frame = frame
        self.children = children
    }
}

/// Condensed accessibility snapshot, matching the original `AppState.accessibility`.
public struct CUAAccessibilityState: Codable, Sendable, Hashable {
    /// Human/model readable tree text: indented lines carrying element indices,
    /// roles, names, values, states and available secondary actions.
    public var tree: String
    public var focusedElement: String?
    public var selectedText: String?
    public var selectedElements: [String]?
    public var documentText: String?

    public init(
        tree: String,
        focusedElement: String? = nil,
        selectedText: String? = nil,
        selectedElements: [String]? = nil,
        documentText: String? = nil
    ) {
        self.tree = tree
        self.focusedElement = focusedElement
        self.selectedText = selectedText
        self.selectedElements = selectedElements
        self.documentText = documentText
    }
}

/// Result of `getAppState`, matching the original mac `AppState` shape.
public struct CUAAppState: Codable, Sendable, Hashable {
    public var app: String
    public var screenshot: CUAScreenshot?
    /// Tree text, prefixed with app-specific guidance when the engine learns one.
    public var text: String
    public var accessibility: CUAAccessibilityState?
    public var windows: [CUAWindowInfo]

    public init(
        app: String,
        screenshot: CUAScreenshot? = nil,
        text: String = "",
        accessibility: CUAAccessibilityState? = nil,
        windows: [CUAWindowInfo] = []
    ) {
        self.app = app
        self.screenshot = screenshot
        self.text = text
        self.accessibility = accessibility
        self.windows = windows
    }
}

// MARK: - Permissions

/// Privacy permissions this service depends on.
public struct CUAPermissions: Codable, Sendable, Hashable {
    public var screenRecording: Bool
    public var accessibility: Bool

    public init(screenRecording: Bool, accessibility: Bool) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
    }

    public var allGranted: Bool { screenRecording && accessibility }
}

/// Capability/version information reported by the service on `ping`.
public struct CUAServerInfo: Codable, Sendable, Hashable {
    public var serverVersion: String
    public var apiVersion: String
    public var platform: String
    public var features: [String]
    public var permissions: CUAPermissions?
    /// Session handle issued by the service on `ping`. Clients echo it back in
    /// every app-targeting request so the service can apply per-session app
    /// authorization.
    public var sessionId: String?

    public init(
        serverVersion: String,
        apiVersion: String,
        platform: String = "macOS",
        features: [String] = [],
        permissions: CUAPermissions? = nil,
        sessionId: String? = nil
    ) {
        self.serverVersion = serverVersion
        self.apiVersion = apiVersion
        self.platform = platform
        self.features = features
        self.permissions = permissions
        self.sessionId = sessionId
    }
}
