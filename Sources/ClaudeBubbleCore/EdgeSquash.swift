import CoreGraphics

/// The orb pressed against a screen edge like a drop of liquid against glass: the side past the edge flattens onto
/// it and the orb spreads along it, then springs back round (with a jiggle) when it's pulled away.
public enum EdgeSquash {
    /// The value for an edge too far away to touch (an edge's distance never needs to read further than this).
    public static let far: Float = 1
    /// The furthest the orb can be pushed into an edge: its centre this far inside it, in radii (negative: past it).
    /// At -0.4 the orb is squeezed to about two thirds of its width, with a broad flat face on the edge.
    public static let deepest: Float = -0.4

    /// How far each edge of `screen` is from the orb's centre, in orb radii: right, top, left, bottom. Under 1 the
    /// orb reaches past that edge. `top` is where the top edge is (under the menu bar); edges in `shared` continue
    /// onto another display, so they never squash.
    public static func edges(centre c: CGPoint, radius r: CGFloat, screen s: CGRect, top: CGFloat,
                             shared: Set<EdgeStrip.Edge> = []) -> SIMD4<Float> {
        guard r > 0 else { return SIMD4(repeating: far) }
        func distance(_ d: CGFloat, _ edge: EdgeStrip.Edge) -> Float {
            shared.contains(edge) ? far : min(far, Float(d / r))
        }
        return [distance(s.maxX - c.x, .right), distance(top - c.y, .top),
                distance(c.x - s.minX, .left), distance(c.y - s.minY, .bottom)]
    }

    /// A springy follow of the edges: a squash keeps up with the edge exactly, a release wobbles back round.
    public struct Spring: Sendable {
        public private(set) var value = SIMD4<Float>(repeating: EdgeSquash.far)
        private var velocity = SIMD4<Float>(repeating: 0)
        /// About 5 wobbles a second, losing most of its swing in three.
        public static let stiffness: Float = 950
        public static let damping: Float = 16

        public init() {}

        public mutating func step(toward target: SIMD4<Float>, dt: Float) {
            // Pressing into an edge follows it at once, so the orb never comes loose from the edge however fast it's
            // pushed; only letting go springs (the jiggle).
            for i in 0..<4 where target[i] < value[i] {
                value[i] = target[i]
                velocity[i] = min(velocity[i], 0)
            }
            // Small steps, so a long frame can't make it blow up.
            var left = min(max(dt, 0), 0.1)
            while left > 0 {
                let h = min(left, 1 / 240)
                let accel = (target - value) * Self.stiffness - velocity * Self.damping
                velocity += accel * h
                value += velocity * h
                left -= h
            }
        }
    }
}
