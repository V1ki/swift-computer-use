import XCTest
@testable import CUACore

final class FramingTests: XCTestCase {
    func testRoundTripSplitAcrossChunks() throws {
        let payload = Data("hello".utf8)
        let framed = CUAFraming.encode(payload)
        var decoder = CUAStreamDecoder()
        XCTAssertEqual(try decoder.append(framed.prefix(2)), [])
        XCTAssertEqual(try decoder.append(framed.dropFirst(2)), [payload])
    }

    func testOversizedFrameRejected() throws {
        var decoder = CUAStreamDecoder(maxMessageBytes: 4)
        var header = UInt32(5).littleEndian
        let data = Data(bytes: &header, count: 4)
        XCTAssertThrowsError(try decoder.append(data))
    }
}
