import Foundation

/// The engine contract: the only surface the service router talks to.
///
/// Implementations are expected to be an `actor` so that per-app accessibility
/// index tables and the last-capture cache stay consistent across concurrent
/// requests.
///
/// Semantics that callers rely on:
/// - `getAppState` (re)builds the element index table for the target app.
///   Subsequent element-targeted calls must resolve `elementIndex` against that
///   table and throw `.elementIndexStale` when the table is missing, or
///   `.elementNotFound` when the index is out of range.
/// - Input methods are background-only unless explicitly opted into activation.
/// - Coordinates are window-relative unless click explicitly selects global space.
public protocol CUAEngine: Sendable {
    /// Current privacy-permission state without prompting.
    func permissions() async -> CUAPermissions

    /// Launches a discoverable application without going through a shell.
    func launchApp(_ app: String) async throws

    /// Installed/known applications, optionally with their open windows.
    func listApps(includeWindows: Bool) async throws -> [CUAAppInfo]

    /// Mapped application windows that can be targeted.
    func listWindows() async throws -> [CUAWindowInfo]

    /// Captures screenshot and/or accessibility tree for one app.
    func getAppState(_ params: GetAppStateParams) async throws -> CUAAppState

    func click(_ params: ClickParams) async throws -> CUAActionResult
    func pressKey(_ params: PressKeyParams) async throws -> CUAActionResult
    func typeText(_ params: TypeTextParams) async throws -> CUAActionResult
    func scroll(_ params: ScrollParams) async throws -> CUAActionResult
    func setValue(_ params: SetValueParams) async throws -> CUAActionResult
    func drag(_ params: DragParams) async throws -> CUAActionResult
    func paste(_ params: PasteParams) async throws -> CUAActionResult
    func selectText(_ params: SelectTextParams) async throws -> CUAActionResult
    func performSecondaryAction(_ params: PerformSecondaryActionParams) async throws -> CUAActionResult

    func ax(_ method: CUAMethod, params: AXParams) async throws -> JSONValue

    /// Raw screenshot capture outside of `getAppState` (display, window or app).
    func captureScreenshot(_ params: CaptureScreenshotParams) async throws -> [CUAScreenshot]

    /// Locate on-screen text (AX tree first, OCR fallback) for AX-less apps.
    func findText(_ params: FindTextParams) async throws -> [CUATextMatch]

    /// Click the best text match; returns the hit that was acted on.
    func clickText(_ params: ClickTextParams) async throws -> CUATextMatch

    /// Toggles whether actions may raise the target app and move the real
    /// cursor. Default is background-only (false).
    func setOptions(activate: Bool) async

    /// Drops cached per-app state (used by `endSession`).
    func resetSessionState() async
}

// MARK: - Defaults

public extension CUAEngine {
    func launchApp(_ app: String) async throws {
        throw CUAError(
            code: .unsupported,
            message: "launchApp is not implemented by this engine"
        )
    }

    func ax(_ method: CUAMethod, params: AXParams) async throws -> JSONValue {
        throw CUAError(code: .unsupported, message: "AX primitives not implemented by this engine")
    }

    func resetSessionState() async {}
}

public extension CUAEngine {
    func setOptions(activate: Bool) async {}

    func findText(_ params: FindTextParams) async throws -> [CUATextMatch] {
        throw CUAError(code: .unsupported, message: "findText is not implemented by this engine")
    }

    func clickText(_ params: ClickTextParams) async throws -> CUATextMatch {
        throw CUAError(code: .unsupported, message: "clickText is not implemented by this engine")
    }
}
