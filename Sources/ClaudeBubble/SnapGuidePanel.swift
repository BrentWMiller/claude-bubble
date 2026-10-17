import AppKit
import ClaudeBubbleCore

/// The dashed centre guides shown while dragging the orb or the island (like Raycast's): two thin lines across the
/// whole screen, either side of where the dragged thing sits when centred. A clear, click-through window.
final class SnapGuidePanel: NSPanel {
    enum Axis {
        /// Lines running top to bottom, at two x positions.
        case vertical
        /// Lines running side to side, at two y positions.
        case horizontal
    }

    private let lines = CAShapeLayer()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        alphaValue = 0
        let view = NSView()
        view.wantsLayer = true
        lines.fillColor = nil
        lines.lineWidth = 1
        lines.lineDashPattern = [6, 6]
        view.layer?.addSublayer(lines)
        contentView = view
    }

    /// Shows the guides on `screen` (screen space), just under `window`; brighter while the drag is snapped.
    func show(on screen: CGRect, axis: Axis, at positions: (CGFloat, CGFloat), snapped: Bool, below window: NSWindow?) {
        if frame != screen { setFrame(screen, display: false) }
        let path = CGMutablePath()
        for p in [positions.0, positions.1] {
            // Half-pixel aligned, so a 1pt line stays crisp.
            switch axis {
            case .vertical:
                let x = (p - screen.minX).rounded() + 0.5
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: screen.height))
            case .horizontal:
                let y = (p - screen.minY).rounded() + 0.5
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: screen.width, y: y))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lines.frame = CGRect(origin: .zero, size: screen.size)
        lines.path = path
        lines.strokeColor = NSColor.white.withAlphaComponent(snapped ? 0.5 : 0.22).cgColor
        CATransaction.commit()
        if let window { order(.below, relativeTo: window.windowNumber) } else { orderFront(nil) }
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}
