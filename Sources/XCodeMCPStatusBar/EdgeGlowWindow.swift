import AppKit
import CoreImage

/// 仿 Apple Intelligence 的屏幕边缘流光：覆盖整块屏幕、不拦截鼠标，持续流动直到窗口释放。
///
/// 一层清晰内核加三层逐级变宽、变柔和的光晕，全部沿屏幕内侧描边；
/// 渐变色标位置周期性随机漂移形成流动感，整体轻微呼吸。
/// 插值交给 Core Animation 渲染服务，避免逐帧在进程内重绘全屏模糊。
@MainActor
final class EdgeGlowWindow: NSWindow {

    private static let palette: [NSColor] = [
        NSColor(red: 0.74, green: 0.51, blue: 0.95, alpha: 1),  // BC82F3
        NSColor(red: 0.96, green: 0.73, blue: 0.92, alpha: 1),  // F5B9EA
        NSColor(red: 0.55, green: 0.62, blue: 1.00, alpha: 1),  // 8D9FFF
        NSColor(red: 1.00, green: 0.40, blue: 0.47, alpha: 1),  // FF6778
        NSColor(red: 1.00, green: 0.73, blue: 0.44, alpha: 1),  // FFBA71
        NSColor(red: 0.78, green: 0.53, blue: 1.00, alpha: 1),  // C686FF
    ]

    /// (描边宽度, 模糊半径)，第一层为不模糊的清晰内核
    private static let layers: [(width: CGFloat, blur: CGFloat)] = [
        (8, 0),
        (14, 6),
        (22, 16),
        (34, 30),
    ]

    private static let cornerRadius: CGFloat = 12
    private static let flowInterval: Duration = .milliseconds(600)
    private static let flowDuration: CFTimeInterval = 1.2

    private var gradientLayers: [CAGradientLayer] = []

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.layer?.addSublayer(makeGlowLayer(bounds: view.bounds))
        contentView = view

        // 窗口释放后 self 为 nil，循环随之结束
        Task { [weak self] in
            while (try? await Task.sleep(for: Self.flowInterval)) != nil, let self {
                self.flow()
            }
        }
    }

    private func makeGlowLayer(bounds: CGRect) -> CALayer {
        let container = CALayer()
        container.frame = bounds

        let stops = Self.randomStops()
        for layer in Self.layers {
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.frame = bounds
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = stops.colors
            gradient.locations = stops.locations

            // 描边整体落在屏幕内侧：路径内缩半个线宽
            let inset = bounds.insetBy(dx: layer.width / 2, dy: layer.width / 2)
            let path = CGPath(
                roundedRect: inset,
                cornerWidth: Self.cornerRadius,
                cornerHeight: Self.cornerRadius,
                transform: nil
            )
            let mask = CAShapeLayer()
            mask.frame = bounds
            mask.path = path
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = layer.width
            gradient.mask = mask

            // 模糊作用在包含已遮罩渐变的宿主层上，得到真实的光晕衰减
            let host = CALayer()
            host.frame = bounds
            host.addSublayer(gradient)
            if layer.blur > 0, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(layer.blur, forKey: kCIInputRadiusKey)
                host.filters = [blur]
            }

            container.addSublayer(host)
            gradientLayers.append(gradient)
        }

        let breathing = CABasicAnimation(keyPath: "opacity")
        breathing.fromValue = 0.8
        breathing.toValue = 1
        breathing.duration = 1.6
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.add(breathing, forKey: "breathing")
        return container
    }

    /// 所有层同步漂移到一组新的随机色标
    private func flow() {
        let stops = Self.randomStops()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.flowDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        for gradient in gradientLayers {
            gradient.colors = stops.colors
            gradient.locations = stops.locations
        }
        CATransaction.commit()
    }

    private static func randomStops() -> (colors: [CGColor], locations: [NSNumber]) {
        let stops = palette
            .map { (color: $0.cgColor, location: Double.random(in: 0...1)) }
            .sorted { $0.location < $1.location }
        let colors = stops.map(\.color)
        let locations = stops.map { NSNumber(value: $0.location) }
        // 0 与 1 两端补同一种颜色，避免锥形渐变在 0°/360° 处出现断层
        return ([colors[0]] + colors + [colors[0]], [0] + locations + [1])
    }
}
