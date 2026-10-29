import XCTest
import ApplicationServices
import CUACore
@testable import CUAEngine

final class PrimitiveTests: XCTestCase {
    func testPresentationBoundsPreserveIndices() {
        let nodes = [CUAAccessibilityNode(index: 7, role: "AXWindow", children: [
            CUAAccessibilityNode(index: 19, role: "AXButton", title: "Find", identifier: "search"),
            CUAAccessibilityNode(index: 42, role: "AXTextField")])]
        let limited = AXFormat.bounded(nodes, limit: 2, depth: 40)
        XCTAssertEqual(limited.nodes[0].children.map(\.index), [19])
        XCTAssertTrue(limited.truncated)
        let shallow = AXFormat.bounded(nodes, limit: 20, depth: 0)
        XCTAssertEqual(shallow.nodes.map(\.index), [7])
        XCTAssertTrue(shallow.nodes[0].children.isEmpty)
        XCTAssertTrue(shallow.truncated)
        XCTAssertFalse(AXFormat.bounded(nodes, limit: 3, depth: 1).truncated)
    }
    func testAXNameAndActivationPolicy() throws {
        XCTAssertEqual(try AXPrimitive.name("axpress", available: ["AXPress"]), "AXPress")
        XCTAssertThrowsError(try AXPrimitive.name("AXDelete", available: ["AXPress"]))
        XCTAssertThrowsError(try AXPrimitive.checkMutation("axraise", activate: false))
        XCTAssertThrowsError(try AXPrimitive.checkMutation("AXFrontmost", activate: false))
        XCTAssertNoThrow(try AXPrimitive.checkMutation("AXFocused", activate: false))
        XCTAssertNoThrow(try AXPrimitive.checkMutation("AXRaise", activate: true))
    }
    func testEvidenceDoesNotClaimSuccess() throws {
        XCTAssertNil(AXPrimitive.changed(before: nil, after: "new"))
        XCTAssertEqual(AXPrimitive.changed(before: "old", after: "new"), true)
        XCTAssertEqual(AXPrimitive.changed(before: "same", after: "same"), false)
        XCTAssertEqual(CUAActionResult().effect, "unverified")
        XCTAssertEqual(CUAActionResult(changed: false).effect, "unverified")
        XCTAssertEqual(CUAActionResult(changed: true).effect, "observed-change")
    }
    func testTypedAXValueRoundTrips() throws {
        for value: JSONValue in ["text", .bool(true), .double(3.5), .object(["x": 2, "y": 3]), .object(["width": 20, "height": 40]), .object(["location": 1, "length": 4])] {
            let roundTrip = AXAccess.json(try AXAccess.writable(value))
            if value == .object(["x": 2, "y": 3]) { XCTAssertEqual(roundTrip["x"]?.doubleValue, 2) }
            else if value == .object(["width": 20, "height": 40]) { XCTAssertEqual(roundTrip["width"]?.doubleValue, 20) }
            else { XCTAssertEqual(roundTrip, value) }
        }
        XCTAssertThrowsError(try AXAccess.writable(.null))
        XCTAssertThrowsError(try AXAccess.writable(.double(.infinity)))
        XCTAssertThrowsError(try AXAccess.writable(.object(["location": -1, "length": 2])))
    }
    func testStructuredStateDecodesOldPayload() throws {
        let state = try CUACodec.decode(CUAAppState.self, from: .object(["app": "test", "text": "", "windows": .array([])]))
        XCTAssertNil(state.info)
        let params = try CUACodec.decode(GetAppStateParams.self, from: .object(["app": "test", "depth": 2, "limit": 5]))
        XCTAssertEqual(params.depth, 2)
        XCTAssertEqual(params.limit, 5)
    }
}
