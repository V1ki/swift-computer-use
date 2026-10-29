import XCTest
import CUACore
@testable import CUAEngine

/// 只验证类型构造，不查询权限、不联系窗口服务器、不触发任何 GUI。
final class SmokeTests: XCTestCase {
    func testEngineConforms() {
        let engine: any CUAEngine = SkyEngine()
        XCTAssertNotNil(engine)
    }
}
