import XCTest
import CUACore
@testable import CUAClient

final class PrimitiveCLITests: XCTestCase {
    private func parameters(command: String, args: CLIArguments) throws -> JSONValue {
        let names = ["info": "get_app_state", "click": "click", "windows": "list_windows", "apps": "list_apps"]
        let tool = try XCTUnwrap(MCPTools.all.first { $0.name == names[command] })
        return try CUACommandLine.parameters(args, command: command, tool: tool)
    }
    func testInfoAndBounds() throws {
        let params = try parameters(command: "info", args: CLIArguments(["info", "--app", "com.apple.finder", "--limit", "20", "--depth", "2"]))
        XCTAssertEqual(params["includeScreenshot"], .bool(false))
        XCTAssertEqual(params["limit"], .int(20))
        XCTAssertEqual(params["depth"], .int(2))
    }
    func testTypedAXSetAndValidation() throws {
        let (method, params) = try CUACommandLine.axParameters(CLIArguments(["ax", "set", "--app", "test", "--element", "3", "--attribute", "AXFocused", "--value-json", "true"]))
        XCTAssertEqual(method, "axSet")
        XCTAssertEqual(params["value"], .bool(true))
        XCTAssertThrowsError(try CUACommandLine.axParameters(CLIArguments(["ax", "set", "--app", "test", "--element", "3", "--attribute", "AXValue"])))
        XCTAssertThrowsError(try CUACommandLine.axParameters(CLIArguments(["ax", "get", "--app", "test", "--element", "-1", "--attribute", "AXRole"])))
    }
    func testCoordinateRouteAndAppFilters() throws {
        let params = try parameters(command: "click", args: CLIArguments(["click", "--app", "test", "--x", "-10", "--y", "3", "--coordinate-space", "global", "--strategy", "coordinate"]))
        XCTAssertEqual(params["coordinateSpace"], "global")
        XCTAssertEqual(params["strategy"], "coordinate")
        XCTAssertNoThrow(try parameters(command: "windows", args: CLIArguments(["windows", "--app", "test"])))
        XCTAssertNoThrow(try parameters(command: "apps", args: CLIArguments(["apps", "--running"])))
    }
}
