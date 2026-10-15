import CoreGraphics

/// Converts between a panel frame and its "spot": the centre as a fraction across and up a display.
public enum RelativePlacement {
    public static func spot(of frame: CGRect, in visible: CGRect) -> CGPoint {
        CGPoint(x: (frame.midX - visible.minX) / visible.width, y: (frame.midY - visible.minY) / visible.height)
    }

    /// The panel origin for `spot` on a display, kept fully inside its visible area.
    public static func origin(for spot: CGPoint, side: CGFloat, in visible: CGRect) -> CGPoint {
        let x = visible.minX + spot.x * visible.width - side / 2
        let y = visible.minY + spot.y * visible.height - side / 2
        return CGPoint(x: min(max(x, visible.minX), visible.maxX - side),
                       y: min(max(y, visible.minY), visible.maxY - side))
    }
}
