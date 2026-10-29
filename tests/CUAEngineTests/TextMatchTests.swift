import XCTest
import CoreGraphics
import CUACore
@testable import CUAEngine

final class TextMatchTests: XCTestCase {
    private func node(_ index: Int, _ text: String?, frame: CUARect? = nil,
                      children: [CUAAccessibilityNode] = []) -> CUAAccessibilityNode {
        CUAAccessibilityNode(index: index, role: "AXStaticText", title: text, frame: frame, children: children)
    }

    func testContainsAndExactMatching() {
        XCTAssertTrue(TextMatch.matches("Codex 零号远征队 (326)", query: "零号", exact: false))
        XCTAssertTrue(TextMatch.matches("Codex 零号远征队", query: "codex 零号", exact: false))
        XCTAssertFalse(TextMatch.matches("Codex 零号远征队", query: "零号", exact: true))
        XCTAssertTrue(TextMatch.matches("Codex 零号远征队", query: "codex 零号远征队", exact: true))
        XCTAssertFalse(TextMatch.matches("abc", query: "   ", exact: false))
    }

    func testTreeSearchConvertsRectsToWindowRelative() {
        let windowOrigin = CUARect(x: 0, y: 33, width: 1512, height: 949)
        let child = node(2, "发送", frame: CUARect(x: 1440, y: 935, width: 48, height: 24))
        let root = node(0, nil, frame: windowOrigin, children: [
            node(1, "会话", frame: CUARect(x: 60, y: 85, width: 240, height: 63), children: [child])
        ])
        let matches = TextMatch.tree([root], query: "发送", exact: false, windowOrigin: windowOrigin)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.index, 2)
        XCTAssertEqual(matches.first?.source, "ax")
        XCTAssertEqual(matches.first?.rect.y ?? 0, 935 - 33, accuracy: 0.001)
    }

    func testPickPrefersAXAndSmallestArea() {
        let big = CUATextMatch(text: "x", rect: CUARect(x: 0, y: 0, width: 200, height: 100), source: "ax")
        let small = CUATextMatch(text: "x", rect: CUARect(x: 0, y: 0, width: 40, height: 20), source: "ax")
        let ocr = CUATextMatch(text: "x", rect: CUARect(x: 0, y: 0, width: 20, height: 10), source: "ocr", confidence: 0.99)
        XCTAssertEqual(TextMatch.pick([big, small, ocr])?.rect.width, 40)
        XCTAssertEqual(TextMatch.pick([ocr])?.source, "ocr")
        XCTAssertNil(TextMatch.pick([]))
    }

    func testOCRBoxConversionUsesTopLeftOrigin() {
        // Vision bounding box: x=0.5, y=0.25 (bottom-left), w=0.25, h=0.1, canvas 1000x500 points
        let rect = VisionText.rect(fromNormalized: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.1),
                                   pointSize: CGSize(width: 1000, height: 500))
        // y = (1 - (0.25 + 0.1)) * 500 = 325
        XCTAssertEqual(rect.x, 500, accuracy: 0.001)
        XCTAssertEqual(rect.y, 325, accuracy: 0.001)
        XCTAssertEqual(rect.width, 250, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
    }
}
