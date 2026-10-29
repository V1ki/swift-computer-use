import XCTest
import CoreGraphics
import CUACore
@testable import CUAEngine

private final class RecordingPoster: EventPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var globals = 0
    private var pids: [pid_t] = []
    func postGlobal(_ event: CGEvent) { lock.lock(); globals += 1; lock.unlock() }
    func post(_ event: CGEvent, to pid: pid_t) { lock.lock(); pids.append(pid); lock.unlock() }
    var counts: (Int, [pid_t]) { lock.lock(); defer { lock.unlock() }; return (globals, pids) }
}

final class InputPolicyTests: XCTestCase {
    func testDefaultDeniesGlobalEvents() throws {
        XCTAssertThrowsError(try InputSynthesis.key(KeyChord.parse("Return"), duration: 0)) {
            XCTAssertEqual(($0 as? CUAError)?.code, .inputRejected)
        }
    }

    func testBackgroundRejectsEveryGlobalPrimitiveBeforePosting() throws {
        let poster = RecordingPoster()
        try InputSynthesis.$context.withValue(InputContext(poster: poster)) {
            let key = try KeyChord.parse("Return")
            let operations: [() throws -> Void] = [
                { try InputSynthesis.post(CGEvent(source: nil)) },
                { try InputSynthesis.key(key, duration: 0) },
                { try InputSynthesis.text("hello 😀") },
                { try InputSynthesis.mouse(.mouseMoved, at: .zero) },
                { try InputSynthesis.click(at: .zero, button: .left, count: 1, flags: [], duration: 0) },
                { try InputSynthesis.paste("not written to clipboard", format: .text) }
            ]
            for operation in operations {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual(($0 as? CUAError)?.code, .inputRejected) }
            }
        }
        XCTAssertEqual(poster.counts.0, 0)
        XCTAssertTrue(poster.counts.1.isEmpty)
    }

    func testBackgroundPrimitivesOnlyUseTargetPoster() throws {
        let poster = RecordingPoster()
        try InputSynthesis.$context.withValue(InputContext(poster: poster)) {
            try InputSynthesis.key(KeyChord.parse("Return"), duration: 0, pid: 123)
            try InputSynthesis.text("x", pid: 123)
            try InputSynthesis.click(at: .zero, button: .left, count: 1, flags: [], duration: 0, pid: 123)
            try InputSynthesis.scroll(at: .zero, dx: 0, dy: 1, pid: 123)
            try InputSynthesis.drag(from: .zero, to: CGPoint(x: 2, y: 3), pid: 123, steps: 1)
        }
        XCTAssertEqual(poster.counts.0, 0)
        XCTAssertEqual(poster.counts.1, Array(repeating: 123, count: 10))
    }

    func testForegroundExplicitlyAllowsGlobalPosterAndRestoresPolicy() throws {
        let poster = RecordingPoster()
        try InputSynthesis.$context.withValue(InputContext(allowActivation: true, poster: poster)) {
            try InputSynthesis.key(KeyChord.parse("Return"), duration: 0)
            try InputSynthesis.text("x")
            try InputSynthesis.mouse(.mouseMoved, at: .zero)
            try InputSynthesis.click(at: .zero, button: .left, count: 1, flags: [], duration: 0)
        }
        XCTAssertEqual(poster.counts.0, 7)
        XCTAssertTrue(poster.counts.1.isEmpty)
        XCTAssertFalse(InputSynthesis.context.allowActivation)
    }

    func testNestedBackgroundScopeCannotInheritForegroundPermission() throws {
        let poster = RecordingPoster()
        try InputSynthesis.$context.withValue(InputContext(allowActivation: true, poster: poster)) {
            try InputSynthesis.$context.withValue(InputContext(poster: poster)) {
                XCTAssertThrowsError(try InputSynthesis.mouse(.leftMouseDown, at: .zero))
            }
            try InputSynthesis.mouse(.leftMouseUp, at: .zero)
        }
        XCTAssertEqual(poster.counts.0, 1)
    }
}
