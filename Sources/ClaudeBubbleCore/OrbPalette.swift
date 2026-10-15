import Foundation

/// The four shader colors for one state, plus the flat color used for pips and color wells.
public struct StateColors: Codable, Equatable, Sendable {
    public var c1, c2, c3, halo, swatch: SIMD3<Float>

    public init(c1: SIMD3<Float>, c2: SIMD3<Float>, c3: SIMD3<Float>, halo: SIMD3<Float>, swatch: SIMD3<Float>) {
        self.c1 = c1; self.c2 = c2; self.c3 = c3; self.halo = halo; self.swatch = swatch
    }
}

public struct OrbPalette: Codable, Equatable, Sendable {
    public var idle, working, needs, error: StateColors

    public init(idle: StateColors, working: StateColors, needs: StateColors, error: StateColors) {
        self.idle = idle; self.working = working; self.needs = needs; self.error = error
    }

    public subscript(state: BubbleState) -> StateColors {
        get {
            switch state {
            case .idle: idle
            case .working: working
            case .needs: needs
            case .error: error
            }
        }
        set {
            switch state {
            case .idle: idle = newValue
            case .working: working = newValue
            case .needs: needs = newValue
            case .error: error = newValue
            }
        }
    }

    // Shared entries, from PAL.claude in the design's orbParticles.js.
    private static let claudeWorking = StateColors(c1: [1, 0.46, 0.2], c2: [0.56, 0.3, 1], c3: [1, 0.45, 0.72],
                                                   halo: [0.3, 0.14, 0.75], swatch: [0.56, 0.3, 1])
    private static let claudeNeeds = StateColors(c1: [1, 0.72, 0.22], c2: [1, 0.38, 0.24], c3: [1, 0.86, 0.55],
                                                 halo: [0.6, 0.24, 0.08], swatch: [1, 0.72, 0.22])
    private static let claudeError = StateColors(c1: [1, 0.2, 0.22], c2: [0.72, 0.08, 0.2], c3: [1, 0.55, 0.45],
                                                 halo: [0.5, 0.03, 0.06], swatch: [1, 0.2, 0.22])

    /// Green done, violet working, yellow needs, red error — matches Claude Code's agents view.
    public static let agentsView = OrbPalette(
        idle: StateColors(c1: [0.42, 0.88, 0.56], c2: [0.22, 0.62, 0.4], c3: [0.72, 0.96, 0.78],
                          halo: [0.06, 0.3, 0.14], swatch: [0.42, 0.88, 0.56]),
        working: claudeWorking,
        needs: StateColors(c1: [1, 0.86, 0.24], c2: [1, 0.66, 0.12], c3: [1, 0.95, 0.62],
                           halo: [0.55, 0.4, 0.04], swatch: [1, 0.86, 0.24]),
        error: claudeError)

    /// PAL.claude exactly as designed.
    public static let originalDesign = OrbPalette(
        idle: StateColors(c1: [0.62, 0.66, 0.82], c2: [0.4, 0.44, 0.62], c3: [0.8, 0.82, 0.95],
                          halo: [0.16, 0.18, 0.34], swatch: [0.62, 0.66, 0.82]),
        working: claudeWorking, needs: claudeNeeds, error: claudeError)

    /// PAL.blue from the design file.
    public static let blue = OrbPalette(
        idle: StateColors(c1: [0.55, 0.6, 1], c2: [0.35, 0.38, 0.85], c3: [0.7, 0.8, 1],
                          halo: [0.08, 0.1, 0.45], swatch: [0.55, 0.6, 1]),
        working: StateColors(c1: [1, 0.3, 0.9], c2: [0.3, 0.78, 1], c3: [1, 0.72, 0.6],
                             halo: [0.12, 0.1, 0.95], swatch: [1, 0.3, 0.9]),
        needs: claudeNeeds, error: claudeError)

    public static let presets: [(name: String, palette: OrbPalette)] = [
        ("Agents view", agentsView), ("Original design", originalDesign), ("Blue", blue)
    ]

    public static func preset(named name: String) -> OrbPalette? {
        presets.first { $0.name == name }?.palette
    }
}

/// Turns one picked color into a full orb state, shaped like the hand-made palettes.
public enum PaletteDerivation {
    public static func colors(from base: SIMD3<Float>) -> StateColors {
        let b = clamp(base)
        let (h, s, v) = hsv(b)
        return StateColors(c1: b,
                           c2: rgb(h: (h - 25 + 360).truncatingRemainder(dividingBy: 360), s: s, v: v * 0.75),
                           c3: clamp(b + (SIMD3<Float>(repeating: 1) - b) * 0.45),
                           halo: b * 0.45,
                           swatch: b)
    }

    /// Hue in degrees, 0..<360.
    public static func hue(of c: SIMD3<Float>) -> Float { hsv(c).h }

    private static func clamp(_ c: SIMD3<Float>) -> SIMD3<Float> {
        c.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
    }

    private static func hsv(_ c: SIMD3<Float>) -> (h: Float, s: Float, v: Float) {
        let mx = c.max(), mn = c.min(), d = mx - mn
        var h: Float = 0
        if d > 0 {
            if mx == c.x { h = 60 * ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
            else { h = 60 * ((c.x - c.y) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    private static func rgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let c = v * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r, g, b): (Float, Float, Float) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        return clamp(SIMD3(r + m, g + m, b + m))
    }
}
