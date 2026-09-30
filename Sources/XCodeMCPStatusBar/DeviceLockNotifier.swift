import AppKit
import MCPServiceCore

/// 将真机锁屏事件转换为每块屏幕上的持续提醒：边缘流光加顶部抖动浮窗，解锁或任务结束时关闭。
@MainActor
final class DeviceLockNotifier {

    /// 浮窗显示期间持续抖动的间隔
    private static let pulseInterval: Duration = .seconds(2)
    private static let panelCornerRadius: CGFloat = 14

    /// 当前处于锁定状态的设备，按锁定先后排列
    private var lockedDevices: [String] = []

    /// 用户手动关闭浮窗时锁定中的设备；这些设备重新锁定前不再弹出
    private var dismissedDevices: Set<String> = []

    /// 每块屏幕各一个浮窗
    private var panels: [NSPanel] = []
    /// 每块屏幕各一层边缘流光
    private var glowWindows: [EdgeGlowWindow] = []
    private var pulseTask: Task<Void, Never>?

    /// 事件通道，保证锁定与回收按 FIFO 顺序处理
    private nonisolated let continuation: AsyncStream<DeviceLockEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: DeviceLockEvent.self)
        self.continuation = continuation
        Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    /// 可在任意并发上下文调用
    nonisolated func send(_ event: DeviceLockEvent) {
        continuation.yield(event)
    }

    private func handle(_ event: DeviceLockEvent) {
        switch event {
        case .locked(let deviceName):
            guard !lockedDevices.contains(deviceName) else { return }
            lockedDevices.append(deviceName)
        case .cleared(let deviceName):
            lockedDevices.removeAll { $0 == deviceName }
            dismissedDevices.remove(deviceName)
        }
        refresh()
    }

    private func refresh() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        glowWindows.forEach { $0.orderOut(nil) }
        glowWindows.removeAll()

        let visibleDevices = lockedDevices.filter { !dismissedDevices.contains($0) }
        guard !visibleDevices.isEmpty else {
            pulseTask?.cancel()
            pulseTask = nil
            return
        }

        let deviceList = ListFormatter.localizedString(byJoining: visibleDevices)
        let title = String(format: StatusBarLocalization.string("deviceLock.title"), deviceList)
        // 流光先上屏，浮窗随后置于其上
        glowWindows = NSScreen.screens.map { screen in
            let glow = EdgeGlowWindow(screen: screen)
            glow.orderFrontRegardless()
            return glow
        }
        panels = NSScreen.screens.map { screen in
            let panel = makePanel(title: title)
            position(panel, on: screen)
            panel.orderFrontRegardless()
            return panel
        }

        guard pulseTask == nil else { return }
        // 提醒结束时任务被取消，sleep 抛出 CancellationError 即结束循环
        pulseTask = Task { [weak self] in
            repeat {
                self?.pulse()
            } while (try? await Task.sleep(for: Self.pulseInterval)) != nil
        }
    }

    /// 抖动所有浮窗，并在手指接触触控板时给出触感反馈
    private func pulse() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        for panel in panels {
            let origin = panel.frame.origin
            let animation = CAKeyframeAnimation()
            animation.values = [0, -24, 24, -18, 18, -10, 10, 0].map {
                NSValue(point: NSPoint(x: origin.x + $0, y: origin.y))
            }
            animation.duration = 0.6
            panel.animations = ["frameOrigin": animation]
            panel.animator().setFrameOrigin(origin)
        }
    }

    @objc private func dismiss() {
        dismissedDevices.formUnion(lockedDevices)
        refresh()
    }

    // MARK: - Panel

    private func makePanel(title: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // 置于普通窗口和全屏应用之上，跨所有桌面显示，且不抢占焦点
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 系统窗口阴影在深色模式下会沿窗口边缘描一圈浅色轮廓
        panel.hasShadow = false

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        // 材质本身不受 layer 圆角裁剪，需用 maskImage 切出圆角
        background.maskImage = Self.roundedMask(radius: Self.panelCornerRadius)
        background.wantsLayer = true
        background.layer?.cornerRadius = Self.panelCornerRadius
        background.layer?.borderWidth = 2
        background.layer?.borderColor = NSColor.systemOrange.cgColor

        let icon = NSImageView(
            image: NSImage(systemSymbolName: "lock.iphone", accessibilityDescription: nil) ?? NSImage()
        )
        icon.symbolConfiguration = .init(pointSize: 30, weight: .semibold)
        icon.contentTintColor = .systemOrange

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail

        let bodyLabel = NSTextField(wrappingLabelWithString: StatusBarLocalization.string("deviceLock.body"))
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.preferredMaxLayoutWidth = 300

        let textStack = NSStackView(views: [titleLabel, bodyLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        let closeButton = NSButton(
            image: NSImage(
                systemSymbolName: "xmark.circle.fill",
                accessibilityDescription: StatusBarLocalization.string("deviceLock.dismiss")
            ) ?? NSImage(),
            target: self,
            action: #selector(dismiss)
        )
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = StatusBarLocalization.string("deviceLock.dismiss")

        let row = NSStackView(views: [icon, textStack, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            row.topAnchor.constraint(equalTo: background.topAnchor),
            row.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        background.layoutSubtreeIfNeeded()
        panel.setContentSize(background.fittingSize)
        return panel
    }

    /// 可拉伸的圆角遮罩，四角保持圆弧，中间区域随视图拉伸
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// 放在屏幕可见区域的顶部居中
    private func position(_ panel: NSPanel, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
    }
}
