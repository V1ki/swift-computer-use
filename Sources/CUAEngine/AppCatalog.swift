import AppKit
import ApplicationServices
import CUACore

/// 使用窗口服务器的全局 points；不通过 NSScreen 的左下角坐标转换。
enum AppCatalog {
    static func identifier(_ app: NSRunningApplication) -> String {
        if let bundle = app.bundleIdentifier, !bundle.isEmpty { return bundle }
        if let executable = app.executableURL?.path, !executable.isEmpty { return executable }
        if let bundlePath = app.bundleURL?.path, !bundlePath.isEmpty { return bundlePath }
        return "pid:\(app.processIdentifier)"
    }
    static func running(_ id: String) throws -> NSRunningApplication {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            identifier($0) == id || $0.bundleURL?.path == id || $0.executableURL?.path == id
        }), !app.isTerminated else {
            throw CUAError(code: .appNotRunning, message: "App '\(id)' is not running")
        }
        return app
    }
    static func windows() -> [CUAWindowInfo] {
        guard let entries = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var focusedAssigned = false
        return entries.compactMap { item in
            guard let layer = item[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let raw = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: raw), bounds.width > 0, bounds.height > 0,
                  let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            let onScreen = item[kCGWindowIsOnscreen as String] as? Bool ?? false
            // CG 列表按前后顺序排列；无 AX 权限时以最前方普通窗口近似焦点。
            let focused = pid == frontPID && onScreen && !focusedAssigned
            if focused { focusedAssigned = true }
            return CUAWindowInfo(id: id, app: identifier(app), title: item[kCGWindowName as String] as? String,
                                 bounds: CUARect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height),
                                 layer: layer, isOnScreen: onScreen, isFocused: focused)
        }
    }
    static func installed() -> [CUAAppInfo] {
        let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications"]
        var apps: [String: CUAAppInfo] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let iterator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator {
                // 跳过深层非应用目录，避免扫描整个开发工具或大型内容包。
                if iterator.level > 4 { iterator.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                iterator.skipDescendants()
                guard let bundle = Bundle(url: url) else { continue }
                let rawID = bundle.bundleIdentifier ?? bundle.executableURL?.path ?? ""
                guard !rawID.isEmpty else { continue }
                let id = rawID
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                apps[id] = CUAAppInfo(id: id, displayName: name, isRunning: false)
            }
        }
        return Array(apps.values)
    }
    /// Real apps expose many helper/zero-sized windows in the window list
    /// (Chromium routinely reports 1×1 windows, find-in-page bubbles, offscreen
    /// back buffers). Rank by usable area so the "main" window wins.
    static func targetWindow(app: String, windowID: UInt32?, windows: [CUAWindowInfo]) throws -> CUAWindowInfo {
        let candidates = windows.filter { $0.app == app }
        if let windowID {
            guard let window = candidates.first(where: { $0.id == windowID }) else {
                throw CUAError(code: .elementNotFound, message: "Window \(windowID) does not belong to \(app)")
            }
            return window
        }
        func area(_ window: CUAWindowInfo) -> Double { window.bounds.width * window.bounds.height }
        let usable = candidates.filter { area($0) > 10_000 }
        let pool = usable.filter(\.isOnScreen).isEmpty
            ? (usable.isEmpty ? candidates : usable)
            : usable.filter(\.isOnScreen)
        if let focused = pool.filter({ $0.isFocused }).max(by: { area($0) < area($1) }) { return focused }
        guard let largest = pool.max(by: { area($0) < area($1) }) ?? candidates.first else {
            throw CUAError(code: .elementNotFound, message: "No window for \(app)")
        }
        return largest
    }

    /// Finds the window-server entry whose bounds match an accessibility frame.
    /// Public AX does not expose CGWindowID, so frame geometry is the bridge.
    static func window(matching frame: CUARect, app: String, windows: [CUAWindowInfo]) -> CUAWindowInfo? {
        let candidates = windows.filter { $0.app == app }
        func distance(_ window: CUAWindowInfo) -> Double {
            abs(window.bounds.x - frame.x) + abs(window.bounds.y - frame.y)
                + abs(window.bounds.width - frame.width) + abs(window.bounds.height - frame.height)
        }
        guard let best = candidates.min(by: { distance($0) < distance($1) }), distance(best) < 8 else { return nil }
        return best
    }
}
