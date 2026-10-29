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
/// - Input methods activate the target app window unless a window id pins them.
/// - Coordinate-based input is window-relative, matching the original client.
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

    func click(_ params: ClickParams) async throws
    func pressKey(_ params: PressKeyParams) async throws
    func typeText(_ params: TypeTextParams) async throws
    func scroll(_ params: ScrollParams) async throws
    func setValue(_ params: SetValueParams) async throws
    func drag(_ params: DragParams) async throws
    func paste(_ params: PasteParams) async throws
    func selectText(_ params: SelectTextParams) async throws
    func performSecondaryAction(_ params: PerformSecondaryActionParams) async throws

    /// Raw screenshot capture outside of `getAppState` (display, window or app).
    func captureScreenshot(_ params: CaptureScreenshotParams) async throws -> [CUAScreenshot]

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

    func resetSessionState() async {}
}
