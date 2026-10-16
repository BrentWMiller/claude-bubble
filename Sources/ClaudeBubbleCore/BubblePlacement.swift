import CoreGraphics

public enum BubblePlacement {
    /// Bottom-center, with the 72pt orb sitting ~80pt above the Dock.
    public static func defaultOrigin(visibleFrame: CGRect, size: CGFloat) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size / 2, y: visibleFrame.minY + 56)
    }

    /// The orb may hang off the left, right and bottom of a screen until its centre is 0.6 of a radius past the edge
    /// (four fifths of its width off, a fifth still showing to grab); at the top it stays wholly below the menu bar.
    public static func clampedOrigin(_ origin: CGPoint, side: CGFloat, screen: CGRect, visible: CGRect) -> CGPoint {
        let radius = side * 0.3, over = radius * 0.6
        let cx = min(max(origin.x + side / 2, screen.minX - over), screen.maxX + over)
        let cy = min(max(origin.y + side / 2, screen.minY - over), visible.maxY - radius)
        return CGPoint(x: cx - side / 2, y: cy - side / 2)
    }

    /// Uses the saved origin only if the bubble's center is still on (or just off, as dragging allows) a connected screen.
    public static func origin(saved: CGPoint?, size: CGFloat, screenFrames: [CGRect], mainVisibleFrame: CGRect) -> CGPoint {
        if let saved {
            let center = CGPoint(x: saved.x + size / 2, y: saved.y + size / 2)
            let slack = size * 0.3
            if screenFrames.contains(where: { $0.insetBy(dx: -slack, dy: -slack).contains(center) }) { return saved }
        }
        return defaultOrigin(visibleFrame: mainVisibleFrame, size: size)
    }

    /// The orb is 0.6 of the panel; only that disc should take clicks, the transparent rest passes them through.
    public static func isOverOrb(_ point: CGPoint, panelFrame: CGRect) -> Bool {
        let dx = point.x - panelFrame.midX, dy = point.y - panelFrame.midY
        let radius = panelFrame.width * 0.3
        return dx * dx + dy * dy <= radius * radius
    }
}
