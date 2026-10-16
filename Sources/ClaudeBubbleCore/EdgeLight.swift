import CoreGraphics
import Foundation

public struct EdgeStrip: Equatable, Sendable {
    public enum Edge: String, Sendable { case left, right, bottom, top }
    public let edge: Edge
    /// Where the light is centred along the edge (an x for bottom/top, a y for left/right), in screen points.
    public let centre: CGFloat
    /// How far the light reaches each way from its centre before it's cut off.
    public let reach: CGFloat
    /// 0…1: how close the orb is.
    public let strength: Double
}

/// A light along the screen's edge when the orb is near it: brightest where the orb meets the edge, fading
/// out over a third of the edge each way.
public enum EdgeLight {
    public static func strips(orbCentre c: CGPoint, orbRadius r: CGFloat, screen s: CGRect) -> [EdgeStrip] {
        let candidates: [(EdgeStrip.Edge, CGFloat, CGFloat, CGFloat)] = [
            (.left, c.x - s.minX, c.y, s.height), (.right, s.maxX - c.x, c.y, s.height),
            (.bottom, c.y - s.minY, c.x, s.width), (.top, s.maxY - c.y, c.x, s.width)
        ]
        return candidates.compactMap { edge, distance, along, length in
            let t = min(max((max(distance, 0) - r) / (2 * r), 0), 1)
            let strength = 1 - Double(t * t * (3 - 2 * t))
            guard strength > 0.01 else { return nil }
            return EdgeStrip(edge: edge, centre: along, reach: length / 3 * 2, strength: strength)
        }
    }

    /// Brightness at `x` points along the edge from the light's centre, for an edge `length` long.
    public static func falloff(_ x: CGFloat, length: CGFloat) -> Double {
        let l = Double(length / 3)
        guard abs(Double(x)) <= 2 * l else { return 0 }
        return exp(-pow(Double(x) / l, 2))
    }
}
