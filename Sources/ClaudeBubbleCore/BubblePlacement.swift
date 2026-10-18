import CoreGraphics

public enum BubblePlacement {
    /// Bottom-center, with the 72pt orb sitting ~80pt above the Dock.
    public static func defaultOrigin(visibleFrame: CGRect, size: CGFloat) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size / 2, y: visibleFrame.minY + 56)
    }

    /// Pushed into the left, right or bottom of a screen the orb squishes against it (EdgeSquash), and stops once
    /// its centre is `EdgeSquash.deepest` of a radius from the edge. Edges in `shared` continue onto another display:
    /// there its centre can go 0.8 of a radius past, on its way across. Past a corner of those the limit is 0.5 of a
    /// radius from the corner, so the pips still fit on screen. At the top it stays wholly below the menu bar.
    public static func clampedOrigin(_ origin: CGPoint, side: CGFloat, screen: CGRect, visible: CGRect,
                                     shared: Set<EdgeStrip.Edge> = []) -> CGPoint {
        let radius = side * 0.3
        func allow(_ edge: EdgeStrip.Edge) -> CGFloat {
            shared.contains(edge) ? radius * 0.8 : -radius * CGFloat(EdgeSquash.deepest)
        }
        let corner = radius * 0.5
        let top = visible.maxY - radius
        var cx = min(max(origin.x + side / 2, screen.minX - allow(.left)), screen.maxX + allow(.right))
        var cy = min(max(origin.y + side / 2, screen.minY - allow(.bottom)), top)
        // Past two edges at once: keep within `corner` of that corner.
        let px = cx < screen.minX ? screen.minX : cx > screen.maxX ? screen.maxX : cx
        let py = cy < screen.minY ? screen.minY : cy
        let dx = cx - px, dy = cy - py, d = hypot(dx, dy)
        if dx != 0, dy != 0, d > corner {
            cx = px + dx / d * corner
            cy = py + dy / d * corner
        }
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
