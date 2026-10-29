import Foundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import CUACore

enum ScreenCapture {
    static func capture(_ params: CaptureScreenshotParams, windows: [CUAWindowInfo]) async throws -> [CUAScreenshot] {
        // 只预检，绝不调用 CGRequestScreenCaptureAccess 或主动触发授权。
        guard CGPreflightScreenCaptureAccess() else { throw CUAError.permissionMissing("ScreenRecording") }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let displayID = params.displayId {
                guard params.app == nil, params.windowId == nil else { throw CUAError.invalidParams("displayId cannot be combined with app/windowId", method: "captureScreenshot") }
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CUAError(code: .elementNotFound, message: "Display not found") }
                return [try await image(filter: SCContentFilter(display: display, excludingWindows: []),
                                        rect: display.frame, scale: scale(for: displayID), app: nil, windowID: nil)]
            }
            var targets: [CUAWindowInfo]
            if let app = params.app {
                targets = windows.filter { $0.app == app && (params.windowId == nil || $0.id == params.windowId) }
            } else if let id = params.windowId {
                targets = windows.filter { $0.id == id }
            } else {
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw CUAError(code: .captureFailed, message: "No display available") }
                return [try await image(filter: SCContentFilter(display: display, excludingWindows: []), rect: display.frame,
                                        scale: scale(for: display.displayID), app: nil, windowID: nil)]
            }
            guard !targets.isEmpty else { throw CUAError(code: .elementNotFound, message: "No matching window to capture") }
            targets.sort { $0.isFocused && !$1.isFocused }
            var screenshots: [CUAScreenshot] = []
            for target in targets {
                guard let window = content.windows.first(where: { $0.windowID == target.id }) else { continue }
                let display = content.displays.max { lhs, rhs in
                    area(lhs.frame.intersection(window.frame)) < area(rhs.frame.intersection(window.frame))
                }
                var screenshot = try await image(filter: SCContentFilter(desktopIndependentWindow: window), rect: window.frame,
                                                  scale: scale(for: display?.displayID ?? CGMainDisplayID()), app: target.app, windowID: target.id)
                screenshot.zIndex = targets.count - screenshots.count
                screenshots.append(screenshot)
            }
            guard !screenshots.isEmpty else { throw CUAError(code: .captureFailed, message: "Windows are not shareable") }
            return screenshots
        } catch let error as CUAError { throw error }
        catch {
            if !CGPreflightScreenCaptureAccess() { throw CUAError.permissionMissing("ScreenRecording") }
            throw CUAError(code: .captureFailed, message: "ScreenCaptureKit: \(error.localizedDescription)")
        }
    }
    private static func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : rect.width * rect.height }
    private static func scale(for display: CGDirectDisplayID) -> Double {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return max(1, Double(mode.pixelWidth) / Double(mode.width))
    }
    private static func image(filter: SCContentFilter, rect: CGRect, scale: Double, app: String?, windowID: UInt32?) async throws -> CUAScreenshot {
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let dimensions = Coordinates.pixels(CUARect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), scale: scale)
        config.width = dimensions.0
        config.height = dimensions.1
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CUAError(code: .captureFailed, message: "Cannot create JPEG encoder")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CUAError(code: .captureFailed, message: "JPEG encoding failed") }
        return CUAScreenshot(url: "data:image/jpeg;base64," + (data as Data).base64EncodedString(), width: rect.width, height: rect.height,
                             originX: rect.minX, originY: rect.minY, app: app, windowId: windowID)
    }
}
