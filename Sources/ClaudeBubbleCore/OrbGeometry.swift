import Foundation

public enum OrbGeometry {
    public static let pointCount = 5200

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
