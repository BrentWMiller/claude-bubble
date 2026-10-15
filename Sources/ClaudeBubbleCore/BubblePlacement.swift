import CoreGraphics

public enum BubblePlacement {
    /// Bottom-center, with the 72pt orb sitting ~80pt above the Dock.
    public static func defaultOrigin(visibleFrame: CGRect, size: CGFloat) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size / 2, y: visibleFrame.minY + 56)
    }

    /// Uses the saved origin only if the bubble's center is still on a connected screen.
    public static func origin(saved: CGPoint?, size: CGFloat, screenFrames: [CGRect], mainVisibleFrame: CGRect) -> CGPoint {
        if let saved {
            let center = CGPoint(x: saved.x + size / 2, y: saved.y + size / 2)
            if screenFrames.contains(where: { $0.contains(center) }) { return saved }
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
