import CoreGraphics

/// The orb flying between its floating spot and the island (switching style): a gentle upward arc, eased at both ends.
public enum StyleMorph {
    /// How far the arc bows out, as a fraction of the distance flown.
    public static let bow: CGFloat = 0.18

    /// Ease in and out (cubic).
    public static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The quadratic curve's control point: off the midpoint, to whichever side is up.
    public static func arcControl(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
        guard length > 1 else { return a }
        var normal = CGPoint(x: -dy / length, y: dx / length)
        if normal.y < 0 || (normal.y == 0 && normal.x > 0) { normal = CGPoint(x: -normal.x, y: -normal.y) }
        return CGPoint(x: (a.x + b.x) / 2 + normal.x * length * bow, y: (a.y + b.y) / 2 + normal.y * length * bow)
    }

    public static func point(on a: CGPoint, _ c: CGPoint, _ b: CGPoint, at t: Double) -> CGPoint {
        let t = CGFloat(t), u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    /// A square panel of `side` centred on `centre`.
    public static func orbFrame(centre: CGPoint, side: CGFloat) -> CGRect {
        CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }
}
