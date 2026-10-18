import Foundation

public enum OrbGeometry {
    public static let pointCount = 5200
    /// Up to this orb size the dots grow with the orb; past it they stay this size and more are added (as many more
    /// as the orb's area grows), so a big orb keeps its fine grain instead of turning into blobs.
    public static let detailDiameter: Double = 400

    /// How many dots an orb of `diameter` draws.
    public static func pointCount(diameter: Double) -> Int {
        guard diameter > detailDiameter else { return pointCount }
        let scale = diameter / detailDiameter
        return Int((Double(pointCount) * scale * scale).rounded())
    }

    /// The orb panel's side the dots are sized for: the panel's own, up to the detail size's.
    public static func dotSizingSide(_ side: Double) -> Double { min(side, detailDiameter / 0.6) }

    /// Evenly spread unit-sphere points as packed xyz triples.
    public static func fibonacciSphere(count: Int = pointCount) -> [Float] {
        let golden = Float.pi * (3 - Float(5).squareRoot())
        var out: [Float] = []
        out.reserveCapacity(count * 3)
        for i in 0..<count {
            let y = 1 - Float(i) / Float(count - 1) * 2
            let r = max(0, 1 - y * y).squareRoot()
            let t = golden * Float(i)
            out += [cos(t) * r, y, sin(t) * r]
        }
        return out
    }
}
