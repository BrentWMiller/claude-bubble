import CoreGraphics

/// How the orb reacts when the pointer comes near it.
public enum PointerInteraction: String, Codable, CaseIterable, Sendable {
    /// The highlight swings toward the cursor, the sphere tilts to look at it, the glow swells.
    case attention
    /// Particles on the near side bulge toward the cursor.
    case magnetic
    case off

    public var label: String {
        switch self {
        case .attention: "Attention"
        case .magnetic: "Magnetic"
        case .off: "Off"
        }
    }
}

public enum PointerProximity {
    /// The orb notices the pointer from this many radii away.
    public static let reach: CGFloat = 2.5

    /// 1 over the orb, fading to 0 at `reach` radii.
    public static func closeness(mouse: CGPoint, centre: CGPoint, radius: CGFloat) -> Float {
        let distance = hypot(mouse.x - centre.x, mouse.y - centre.y)
        let t = (distance - radius) / (radius * (reach - 1))
        return Float(min(max(1 - t, 0), 1))
    }

    /// Unit vector from the orb's centre to the pointer (zero when exactly centred).
    public static func direction(mouse: CGPoint, centre: CGPoint) -> SIMD2<Float> {
        let v = SIMD2(Float(mouse.x - centre.x), Float(mouse.y - centre.y))
        let length = (v * v).sum().squareRoot()
        return length > 0 ? v / length : .zero
    }
}
