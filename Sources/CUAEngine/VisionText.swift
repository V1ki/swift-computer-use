import Foundation
import Vision
import CoreGraphics
import ImageIO
import CUACore

/// One text box recognized on a window screenshot.
public struct OCRTextBox: Sendable, Hashable {
    public var text: String
    /// Window-relative rect in points, top-left origin.
    public var rect: CUARect
    public var confidence: Double
}

/// Thin wrapper over the Vision text recognizer.
///
/// This is the fallback path for applications that do not expose a usable
/// accessibility tree (custom-drawn UI, games, some CEF shells). It is only
/// used when AX lookup finds nothing, so normal apps never pay the OCR cost.
public enum VisionText {
    public static let languages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Recognizes text in a `data:image/...;base64,…` screenshot.
    /// - Parameters:
    ///   - dataURL: screenshot data URL produced by ScreenCaptureKit.
    ///   - pointSize: the window size in points (the screenshot is in pixels).
    public static func recognize(dataURL: String, pointSize: CGSize) throws -> [OCRTextBox] {
        guard let image = decode(dataURL: dataURL) else {
            throw CUAError(code: .captureFailed, message: "Cannot decode screenshot for OCR")
        }
        return try recognize(cgImage: image, pointSize: pointSize)
    }

    public static func recognize(cgImage: CGImage, pointSize: CGSize) throws -> [OCRTextBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        // Default is 1/32 of the image height, which ignores 11–13pt UI labels
        // (at 2× that is ~59px). 0.005 keeps small toolbar/sidebar text while
        // still filtering single-pixel noise.
        request.minimumTextHeight = 0.005
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw CUAError(code: .internalError, message: "Vision OCR failed: \(error.localizedDescription)")
        }
        let observations = request.results ?? []
        let size = pointSize.width > 0 && pointSize.height > 0
            ? pointSize
            : CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        var boxes: [OCRTextBox] = []
        boxes.reserveCapacity(observations.count)
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let recognized = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recognized.isEmpty else { continue }
            boxes.append(OCRTextBox(text: recognized,
                                    rect: rect(fromNormalized: observation.boundingBox, pointSize: size),
                                    confidence: Double(candidate.confidence)))
        }
        // reading order: top-to-bottom, then left-to-right
        return boxes.sorted { lhs, rhs in
            if abs(lhs.rect.y - rhs.rect.y) > 4 { return lhs.rect.y < rhs.rect.y }
            return lhs.rect.x < rhs.rect.x
        }
    }

    /// Vision uses normalized coordinates with a bottom-left origin; CUATextMatch
    /// wants points with a top-left origin.
    static func rect(fromNormalized box: CGRect, pointSize: CGSize) -> CUARect {
        let x = Double(box.minX) * Double(pointSize.width)
        let y = (1 - Double(box.maxY)) * Double(pointSize.height)
        let width = Double(box.width) * Double(pointSize.width)
        let height = Double(box.height) * Double(pointSize.height)
        return CUARect(x: x, y: y, width: width, height: height)
    }

    private static func decode(dataURL: String) -> CGImage? {
        let base64: String
        if let comma = dataURL.firstIndex(of: ",") {
            base64 = String(dataURL[dataURL.index(after: comma)...])
        } else {
            base64 = dataURL
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
