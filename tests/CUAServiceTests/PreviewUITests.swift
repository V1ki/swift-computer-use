import XCTest
import Foundation
@testable import CUAService

final class PreviewUITests: XCTestCase {
    func testTitleUsesAppOrWindowID() {
        XCTAssertEqual(PreviewLayout.title(app: " Safari ", windowID: 42), "SwiftCUA · Safari")
        XCTAssertEqual(PreviewLayout.title(app: nil, windowID: 42), "SwiftCUA · 42")
        XCTAssertEqual(PreviewLayout.title(app: " \n", windowID: 42), "SwiftCUA · 42")
    }

    func testClampSupportsNegativeScreenCoordinates() {
        let screen = CGRect(x: -1440, y: 24, width: 1440, height: 876)
        let size = CGSize(width: 320, height: 220)
        XCTAssertEqual(PreviewLayout.clampedOrigin(CGPoint(x: 50, y: 1000), size: size, visibleFrame: screen),
                       CGPoint(x: -320, y: 680))
        XCTAssertEqual(PreviewLayout.clampedOrigin(CGPoint(x: -2000, y: -100), size: size, visibleFrame: screen),
                       CGPoint(x: -1440, y: 24))
        XCTAssertEqual(PreviewLayout.clampedOrigin(CGPoint(x: -600, y: 200), size: size, visibleFrame: screen),
                       CGPoint(x: -600, y: 200))
    }

    func testOversizedPanelAnchorsToVisibleOrigin() {
        XCTAssertEqual(PreviewLayout.clampedOrigin(.zero, size: CGSize(width: 320, height: 220),
                                                  visibleFrame: CGRect(x: 10, y: 20, width: 100, height: 100)),
                       CGPoint(x: 10, y: 20))
    }

    func testHeadlessFlagAndEnvironmentWithoutCreatingApplication() throws {
        XCTAssertTrue(try ServiceOptions(arguments: ["--headless"], environment: [:]).headless)
        XCTAssertTrue(try ServiceOptions(arguments: [], environment: ["SWIFTCUA_HEADLESS": "1"]).headless)
        XCTAssertFalse(try ServiceOptions(arguments: [], environment: [:]).headless)
        XCTAssertFalse(try ServiceOptions(arguments: [], environment: ["SWIFTCUA_HEADLESS": "0"]).headless)
        let options = try ServiceOptions(arguments: ["--headless", "--print-socket", "--no-peer-check"], environment: [:])
        XCTAssertTrue(options.printSocket)
        XCTAssertTrue(options.bypassPeer)
    }
}
