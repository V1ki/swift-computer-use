import XCTest
import CoreGraphics
import CUACore
@testable import CUAEngine

final class EngineUtilitiesTests: XCTestCase {
    func testNestedTreeStatesActionsAndFrames() {
        let leaf = CUAAccessibilityNode(index: 12, role: "AXButton", title: "OK", states: ["enabled", "focused"], actions: ["AXPress"], frame: CUARect(x: -100, y: 20, width: 80, height: 30))
        let root = CUAAccessibilityNode(index: 0, role: "AXWindow", title: "Dialog", children: [CUAAccessibilityNode(index: 3, role: "AXGroup", children: [leaf])])
        let text = AXFormat.render([root], windowTitle: "Dialog")
        XCTAssertTrue(text.hasPrefix("Window: \"Dialog\"; elements=3; truncated=false"))
        XCTAssertTrue(text.contains("    [12] button \"OK\" {enabled, focused} actions=[AXPress] frame=(-100.0,20.0,80.0,30.0)"))
    }
    func testTruncationEscapingHiddenAndInvalidNodes() {
        let value = String(repeating: "界", count: 90)
        let root = CUAAccessibilityNode(index: 0, role: "AXTextField", title: "a\n\"b", value: value, description: "hint", children: [
            CUAAccessibilityNode(index: 1, role: "AXButton", states: ["hidden"]),
            CUAAccessibilityNode(index: 2, role: "AXButton", states: ["invalid"]),
            CUAAccessibilityNode(index: 3, role: "")])
        let result = AXFormat.render([root], truncated: true)
        XCTAssertTrue(result.contains("elements=1; truncated=true"))
        XCTAssertTrue(result.contains("a\\n\\\"b"))
        XCTAssertTrue(result.contains(String(repeating: "界", count: 80) + "…"))
        XCTAssertFalse(result.contains(String(repeating: "界", count: 81)))
        XCTAssertTrue(result.contains("description=\"hint\""))
    }
    func testQueryPreservesAncestorsAndIndices() {
        let root = CUAAccessibilityNode(index: 0, role: "AXWindow", children: [
            CUAAccessibilityNode(index: 1, role: "AXGroup", children: [CUAAccessibilityNode(index: 2, role: "AXButton", title: "Save")]),
            CUAAccessibilityNode(index: 3, role: "AXButton", title: "Cancel")])
        let filtered = AXFormat.filter([root], query: "sAVE")
        XCTAssertEqual(filtered.first?.index, 0)
        XCTAssertEqual(filtered.first?.children.count, 1)
        XCTAssertEqual(filtered.first?.children.first?.children.first?.index, 2)
        XCTAssertTrue(AXFormat.filter([root], query: "missing").isEmpty)
    }
    func testKeyChords() throws {
        let control = try KeyChord.parse("Control_L+a")
        XCTAssertEqual(control.keyCode, 0)
        XCTAssertEqual(control.flags, .maskControl)
        let combined = try KeyChord.parse("Ctrl+Alt+Shift+Cmd+F20")
        XCTAssertEqual(combined.keyCode, 90)
        XCTAssertTrue(combined.flags.contains([.maskControl, .maskAlternate, .maskShift, .maskCommand]))
        XCTAssertEqual(try KeyChord.parse("Meta+Return").keyCode, 36)
        XCTAssertEqual(try KeyChord.parse("Super+Tab").flags, .maskCommand)
        XCTAssertEqual(try KeyChord.parse("KP_9").keyCode, 92)
        XCTAssertEqual(try KeyChord.parse("Escape").keyCode, 53)
        XCTAssertEqual(try KeyChord.parse("space").keyCode, 49)
        XCTAssertEqual(try KeyChord.parse("Left").keyCode, 123)
        XCTAssertEqual(try KeyChord.parse("semicolon").keyCode, 41)
        XCTAssertEqual(try KeyChord.parse("界").unicode, "界")
        XCTAssertEqual(try KeyChord.parse("Control_L").keyCode, 59)
        XCTAssertTrue(try KeyChord.parse("A").flags.contains(.maskShift))
        XCTAssertTrue(try KeyChord.parse("question").flags.contains(.maskShift))
        XCTAssertEqual(try KeyChord.parse("+").keyCode, 24)
        XCTAssertTrue(try KeyChord.parse("Cmd++").flags.contains([.maskCommand, .maskShift]))
    }
    func testInvalidKeyChords() {
        for key in ["", "Ctrl+", "+a", "Ctrl++a", "NotAMod+a", "F21", "KP_99", "banana", "\n"] {
            XCTAssertThrowsError(try KeyChord.parse(key), key) { error in
                XCTAssertEqual((error as? CUAError)?.code, .invalidParams)
            }
        }
    }
    func testCoordinatesPreserveNegativeOriginsAndSeparateScale() {
        let window = CUARect(x: -1920, y: -200, width: 800, height: 600)
        XCTAssertEqual(Coordinates.global(CUAPoint(x: 25, y: 50), in: window), CGPoint(x: -1895, y: -150))
        XCTAssertEqual(Coordinates.center(window), CGPoint(x: -1520, y: 100))
        let pixels = Coordinates.pixels(window, scale: 2)
        XCTAssertEqual(pixels.0, 1600); XCTAssertEqual(pixels.1, 1200)
        XCTAssertEqual(Coordinates.global(CUAPoint(x: 25, y: 50), in: window).x, -1895)
    }
    func testIndexExpiryAndIdentity() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let stamp = IndexStamp(pid: 42, windowID: 10, capturedAt: now)
        XCTAssertNoThrow(try stamp.validate(pid: 42, windowID: 10, now: now.addingTimeInterval(119)))
        XCTAssertNoThrow(try stamp.validate(pid: 42, windowID: nil, now: now))
        for (pid, window, date) in [(Int32(43), UInt32(10), now), (42, 11, now), (42, 10, now.addingTimeInterval(121)), (42, 10, now.addingTimeInterval(-1))] {
            XCTAssertThrowsError(try stamp.validate(pid: pid, windowID: window, now: date)) { error in
                XCTAssertEqual((error as? CUAError)?.code, .elementIndexStale)
            }
        }
        XCTAssertEqual(try IndexStamp.requireIndex(0, in: [0: "element"]), "element")
        XCTAssertThrowsError(try IndexStamp.requireIndex(9, in: [0: "element"])) { error in
            XCTAssertEqual((error as? CUAError)?.code, .elementNotFound)
        }
    }
    func testUTF16ChunksNeverSplitSurrogates() {
        let source = String(repeating: "a", count: 19) + "😀" + String(repeating: "界", count: 30) + "𐐀"
        let chunks = TextInput.chunks(source)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), source)
        XCTAssertEqual(chunks[0].count, 19)
        XCTAssertEqual(TextInput.chunks("").count, 0)
    }
    func testSelectionOffsetsUseUTF16AndContext() throws {
        let source = "😀 same first same last"
        let selection = try TextInput.selection(in: source, text: "same", prefix: "first ", suffix: " last", type: .text)
        XCTAssertEqual(selection.location, 14)
        XCTAssertEqual(selection.length, 4)
        let before = try TextInput.selection(in: source, text: "same", prefix: "first ", suffix: nil, type: .cursorBefore)
        XCTAssertEqual(before.location, 14); XCTAssertEqual(before.length, 0)
        let after = try TextInput.selection(in: source, text: "same", prefix: "first ", suffix: nil, type: .cursorAfter)
        XCTAssertEqual(after.location, 18); XCTAssertEqual(after.length, 0)
        XCTAssertThrowsError(try TextInput.selection(in: source, text: "missing", prefix: nil, suffix: nil, type: .text))
    }
}
