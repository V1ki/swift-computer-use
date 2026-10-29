import XCTest
import CoreGraphics
import CoreText
import Foundation
@testable import CUAEngine

#if canImport(Vision)
final class VisionTextTests: XCTestCase {
    /// Draws text into a bitmap and checks the Vision pipeline finds it and maps
    /// the box back into points (this is the OCR fallback used for AX-less apps).
    func testRecognizesRenderedText() throws {
        let width = 600, height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let font = CTFontCreateWithName("Helvetica" as CFString, 48, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SwiftCUA OCR", attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        let image = context.makeImage()!

        let boxes = try VisionText.recognize(cgImage: image, pointSize: CGSize(width: width, height: height))
        let joined = boxes.map(\.text).joined(separator: " ")
        XCTAssertTrue(joined.localizedCaseInsensitiveContains("SwiftCUA"), "OCR output: \(joined)")
        let hit = boxes.first { $0.text.localizedCaseInsensitiveContains("SwiftCUA") }
        XCTAssertNotNil(hit)
        XCTAssertGreaterThan(hit?.rect.width ?? 0, 10)
        XCTAssertGreaterThan(hit?.confidence ?? 0, 0.2)
    }

    func testRejectsUndecodableDataURL() {
        XCTAssertThrowsError(try VisionText.recognize(dataURL: "data:image/jpeg;base64,AAAA", pointSize: CGSize(width: 10, height: 10)))
    }
}
#endif
