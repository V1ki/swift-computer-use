import AppKit
import CUACore
import CUAEngine

/// 不依赖 NSApplication 的格式/几何逻辑，便于在无窗口测试环境验证。
enum PreviewLayout {
    static func title(app: String?, windowID: UInt32) -> String {
        let raw = app?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return "SwiftCUA · \(windowID)" }
        // 传入的通常是 bundle id；优先显示用户熟悉的应用名。
        let display = NSRunningApplication.runningApplications(withBundleIdentifier: raw).first?.localizedName ?? raw
        return "SwiftCUA · \(display)"
    }

    static func clampedOrigin(_ origin: NSPoint, size: NSSize, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - size.width)),
                y: min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - size.height)))
    }
}

@MainActor
private final class PreviewPanel: NSPanel {
    // 即使用户点击预览，也不能把键盘焦点从正在工作的应用拿走。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PreviewUI: NSObject, NSWindowDelegate {
    private static let positionKey = "SwiftCUA.previewPanel.origin"
    private let panel: PreviewPanel
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "SwiftCUA")
    private var statusItem: NSStatusItem?
    private var subscriptionTask: Task<Void, Never>?
    private var subscriptionToken: UUID?
    private var idleTask: Task<Void, Never>?
    private var generation = 0
    private var manuallyHidden = false
    private var isStopped = false

    override init() {
        panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
                             styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        super.init()
        configurePanel()
        installStatusItem()
        subscriptionTask = Task { [weak self] in
            let token = await PreviewHub.shared.subscribe { [weak self] frame in
                // 总线上只传 Sendable JPEG；NSImage 必须留在 MainActor 解码。
                Task { @MainActor [weak self] in self?.update(frame) }
            }
            guard let self else {
                await PreviewHub.shared.unsubscribe(token)
                return
            }
            if self.isStopped { await PreviewHub.shared.unsubscribe(token) }
            else { self.subscriptionToken = token }
        }
    }

    private func configurePanel() {
        // nonactivating + orderFrontRegardless 只展示画面，不激活服务、不碰物理光标。
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.delegate = self
        panel.title = "SwiftCUA"
        // Auto Layout 会按 fitting size 反推窗口，锁死尺寸避免面板被撑大。
        panel.contentMinSize = NSSize(width: 320, height: 220)
        panel.contentMaxSize = NSSize(width: 320, height: 220)

        // 手动 frame 布局：Auto Layout 会按 fitting size 把窗口撑大（实测 320×220
        // 被拉成 496×310），预览面板应保持固定小尺寸。
        let contentSize = NSSize(width: 320, height: 220)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentSize))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        panel.contentView = background
        panel.setContentSize(contentSize)

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stop = NSButton(title: "停止共享", target: self, action: #selector(stopSharing))
        stop.bezelStyle = .inline
        stop.font = .systemFont(ofSize: 10)
        let close = NSButton(title: "×", target: self, action: #selector(hidePreview))
        close.bezelStyle = .inline
        close.font = .systemFont(ofSize: 17)
        close.setAccessibilityLabel("隐藏预览")
        for button in [stop, close] { button.refusesFirstResponder = true }
        let toolbar = NSStackView(views: [titleLabel, stop, close])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.distribution = .fill
        toolbar.alignment = .centerY
        toolbar.frame = NSRect(x: 12, y: contentSize.height - 33, width: contentSize.width - 22, height: 26)
        toolbar.autoresizingMask = [.minYMargin, .width]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityLabel("共享窗口预览")
        imageView.frame = NSRect(x: 8, y: 8, width: contentSize.width - 16, height: contentSize.height - 46)
        imageView.autoresizingMask = [.width, .height]
        background.addSubview(toolbar)
        background.addSubview(imageView)
        restorePosition()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "SwiftCUA")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "SwiftCUA"
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action) in [("显示预览", #selector(showPreview)), ("隐藏预览", #selector(hidePreview)),
                                ("停止共享", #selector(stopSharing))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let version = NSMenuItem(title: "版本 \(CUAProtocolVersion.serviceVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        let quit = NSMenuItem(title: "退出 SwiftCUA", action: #selector(quitService), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    func update(_ frame: CUAPreviewFrame) {
        guard !isStopped, let image = NSImage(data: frame.jpeg) else { return }
        imageView.image = image
        titleLabel.stringValue = PreviewLayout.title(app: frame.app, windowID: frame.windowID)
        guard !manuallyHidden else { return }
        reveal()
        scheduleIdleHide()
    }

    @objc private func showPreview() {
        guard !isStopped else { return }
        manuallyHidden = false
        reveal()
        scheduleIdleHide()
    }

    private func reveal() {
        generation += 1
        // 新帧可能在旧淡出动画中抵达；取消旧动画的视觉效果及其完成回调资格。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        if !panel.isVisible {
            keepOnScreen()
            panel.orderFrontRegardless()
        }
    }

    @objc private func hidePreview() {
        manuallyHidden = true
        hideImmediately()
    }

    private func hideImmediately() {
        generation += 1
        idleTask?.cancel()
        idleTask = nil
        panel.orderOut(nil)
    }

    @objc private func stopSharing() {
        hideImmediately()
        imageView.image = nil
        // 停止 SCStream 会异步等待系统，不能堵塞菜单栏与 AppKit 事件循环。
        Task { await WindowStream.shared.stopAll() }
    }

    @objc private func quitService() { NSApp.terminate(nil) }

    private func scheduleIdleHide() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        let expectedGeneration = generation
        // 以收到帧的单调时钟计时，不用生产端 Date，避免系统校时导致预览常驻。
        // generation 防止淡出完成后误隐藏刚刚恢复的实时画面。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.panel.orderOut(nil)
                self.imageView.image = nil
            }
        }
    }

    private func restorePosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let saved = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double]
        let origin: NSPoint
        if let saved, saved.count == 2, saved.allSatisfy({ $0.isFinite }) {
            origin = NSPoint(x: saved[0], y: saved[1])
        } else {
            origin = NSPoint(x: visible.maxX - panel.frame.width - 16, y: visible.maxY - panel.frame.height - 16)
        }
        panel.setFrameOrigin(origin)
        keepOnScreen()
    }

    private func keepOnScreen() {
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? NSScreen.main
        guard let screen else { return }
        panel.setFrameOrigin(PreviewLayout.clampedOrigin(panel.frame.origin, size: panel.frame.size,
                                                        visibleFrame: screen.visibleFrame))
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set([Double(panel.frame.origin.x), Double(panel.frame.origin.y)], forKey: Self.positionKey)
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        hideImmediately()
        imageView.image = nil
        panel.delegate = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        // 先等订阅安装完成，覆盖“启动后立即退出”的竞争，确保没有遗留观察者。
        await subscriptionTask?.value
        subscriptionTask = nil
        if let subscriptionToken {
            await PreviewHub.shared.unsubscribe(subscriptionToken)
            self.subscriptionToken = nil
        }
    }
}
