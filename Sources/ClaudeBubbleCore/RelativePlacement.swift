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

/// Decides when the orb should hop to the display under the pointer, and where it lands.
public enum PointerFollow {
    public struct Display: Equatable, Sendable {
        public let frame: CGRect
        public let visible: CGRect
        public init(frame: CGRect, visible: CGRect) {
            self.frame = frame
            self.visible = visible
        }
    }

    /// Where the spot falls before the user has placed the orb: bottom-centre.
    public static let defaultSpot = CGPoint(x: 0.5, y: 0.1)

    /// The new panel origin, or nil to stay put. Never moves while a mouse button is down, so dragging
    /// the orb across displays isn't hijacked.
    public static func destination(enabled: Bool, buttonDown: Bool, mouse: CGPoint, panelFrame: CGRect,
                                   displays: [Display], spot: CGPoint?) -> CGPoint? {
        let centre = CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        // An orb hanging off its display's edge (centre just past it) still belongs to that display.
        let slack = panelFrame.width * 0.3
        let home = displays.first { $0.frame.contains(centre) }
            ?? displays.first { $0.frame.insetBy(dx: -slack, dy: -slack).contains(centre) }
        guard enabled, !buttonDown,
              let target = displays.first(where: { $0.frame.contains(mouse) }), target != home else { return nil }
        // The spot may sit past an edge (the orb was hanging off it): it lands hanging off the same edge.
        let s = spot ?? defaultSpot, v = target.visible, side = panelFrame.width
        let raw = CGPoint(x: v.minX + s.x * v.width - side / 2, y: v.minY + s.y * v.height - side / 2)
        return BubblePlacement.clampedOrigin(raw, side: side, screen: target.frame, visible: v)
    }
}
