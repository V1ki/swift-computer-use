import XCTest
import AppKit
import ApplicationServices
import CUACore
@testable import CUAEngine

/// Opt-in, read-only, no app launch, screenshot, activation, or event posting.
final class PrimitiveLiveTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyInspection() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTCUA_LIVE_PRIMITIVES"] == "1" else { throw XCTSkip("Set SWIFTCUA_LIVE_PRIMITIVES=1 for read-only desktop probe") }
        let engine = SkyEngine()
        let before = await engine.desktopInfo()
        print("LIVE desktopBefore=\(before)")
        print("LIVE permissions=\(await engine.permissions())")
        for app in ["com.apple.TextEdit", "com.apple.finder", "com.tencent.xinWeChat"] {
            do {
                var params = GetAppStateParams(app: app, includeScreenshot: false)
                params.limit = 12; params.depth = 2
                let state = try await engine.getAppState(params)
                print("LIVE app=\(app) info=\(state.info ?? .null) roots=\(state.accessibility?.nodes?.count ?? 0) truncated=\(state.accessibility?.truncated ?? false)")
                if let first = state.accessibility?.nodes?.first {
                    let ax = try CUACodec.decode(AXParams.self, from: .object(["app": .string(app), "elementIndex": .int(first.index), "attribute": "AXRole"]))
                    let role = try await engine.ax(.axGet, params: ax)
                    let attrs = try await engine.ax(.axAttributes, params: ax)
                    let actions = try await engine.ax(.axActions, params: ax)
                    print("LIVE role=\(role) attributeCount=\(attrs["attributes"]?.arrayValue?.count ?? 0) actions=\(actions)")
                }
            } catch { print("LIVE app=\(app) unavailable=\(error)") }
        }
        let after = await engine.desktopInfo()
        print("LIVE desktopAfter=\(after)")
        XCTAssertEqual(before["frontmostPID"], after["frontmostPID"], "Read-only probe must not change foreground")
        XCTAssertEqual(before["cursor"], after["cursor"], "Read-only probe must not move cursor (manual user movement also changes this)")
    }
}
