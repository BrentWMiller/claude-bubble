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

    // MARK: Themes

    /// One state's look: the main, secondary and highlight colours plus the halo (the swatch is the main colour).
    private static func s(_ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ c3: SIMD3<Float>, _ halo: SIMD3<Float>) -> StateColors {
        StateColors(c1: c1, c2: c2, c3: c3, halo: halo, swatch: c1)
    }

    /// Northern lights: mint at rest, green into violet while working, rose when it needs you.
    public static let aurora = OrbPalette(
        idle: s([0.45, 0.95, 0.8], [0.2, 0.55, 0.6], [0.75, 1, 0.95], [0.05, 0.3, 0.28]),
        working: s([0.25, 1, 0.6], [0.45, 0.28, 1], [0.4, 1, 0.8], [0.08, 0.32, 0.42]),
        needs: s([1, 0.55, 0.85], [0.6, 0.3, 0.9], [1, 0.85, 0.95], [0.45, 0.1, 0.35]),
        error: s([1, 0.25, 0.4], [0.6, 0.05, 0.3], [1, 0.6, 0.65], [0.5, 0.03, 0.12]))

    /// Deep water: navy at rest, cyan surf while working, warm sand when it needs you, coral for errors.
    public static let ocean = OrbPalette(
        idle: s([0.35, 0.5, 0.95], [0.12, 0.2, 0.55], [0.65, 0.8, 1], [0.03, 0.1, 0.35]),
        working: s([0.2, 0.85, 1], [0.1, 0.35, 0.85], [0.7, 0.95, 1], [0.02, 0.25, 0.5]),
        needs: s([1, 0.85, 0.5], [0.9, 0.55, 0.3], [1, 0.95, 0.8], [0.45, 0.3, 0.08]),
        error: s([1, 0.4, 0.35], [0.75, 0.15, 0.3], [1, 0.7, 0.6], [0.5, 0.08, 0.1]))

    /// Golden hour: dusky lavender at rest, orange into pink while working, gold, then crimson.
    public static let sunset = OrbPalette(
        idle: s([0.75, 0.6, 0.9], [0.45, 0.3, 0.6], [0.92, 0.82, 1], [0.28, 0.15, 0.38]),
        working: s([1, 0.5, 0.12], [0.95, 0.15, 0.48], [1, 0.72, 0.25], [0.55, 0.12, 0.18]),
        needs: s([1, 0.85, 0.3], [1, 0.55, 0.15], [1, 0.95, 0.7], [0.5, 0.32, 0.05]),
        error: s([0.9, 0.1, 0.2], [0.45, 0.02, 0.2], [1, 0.45, 0.45], [0.4, 0.02, 0.08]))

    /// Eighties neon: hot pink and cyan while working, electric yellow when it needs you.
    public static let synthwave = OrbPalette(
        idle: s([0.55, 0.4, 0.95], [0.25, 0.12, 0.55], [0.8, 0.7, 1], [0.15, 0.05, 0.4]),
        working: s([1, 0.1, 0.7], [0, 0.85, 1], [0.25, 1, 1], [0.4, 0, 0.5]),
        needs: s([1, 0.95, 0.25], [1, 0.45, 0.6], [1, 1, 0.7], [0.5, 0.4, 0.05]),
        error: s([1, 0.15, 0.25], [0.55, 0.0, 0.35], [1, 0.55, 0.55], [0.5, 0.0, 0.15]))

    /// Phosphor terminal: dim green at rest, bright green while working, amber, then red.
    public static let matrix = OrbPalette(
        idle: s([0.25, 0.6, 0.35], [0.1, 0.35, 0.15], [0.5, 0.85, 0.55], [0.02, 0.18, 0.05]),
        working: s([0.3, 1, 0.45], [0.05, 0.6, 0.25], [0.75, 1, 0.75], [0.02, 0.35, 0.08]),
        needs: s([1, 0.75, 0.2], [0.8, 0.45, 0.05], [1, 0.9, 0.55], [0.45, 0.25, 0.02]),
        error: s([1, 0.2, 0.15], [0.6, 0.05, 0.05], [1, 0.55, 0.45], [0.45, 0.02, 0.02]))

    /// Black and white: silver at rest, pure white while working, cream when it needs you, a single red accent.
    public static let mono = OrbPalette(
        idle: s([0.55, 0.57, 0.62], [0.3, 0.31, 0.36], [0.78, 0.8, 0.85], [0.12, 0.13, 0.16]),
        working: s([0.95, 0.95, 1], [0.55, 0.57, 0.65], [1, 1, 1], [0.3, 0.3, 0.36]),
        needs: s([1, 0.86, 0.62], [0.7, 0.6, 0.45], [1, 0.95, 0.85], [0.35, 0.28, 0.15]),
        error: s([1, 0.3, 0.3], [0.55, 0.15, 0.15], [1, 0.6, 0.6], [0.4, 0.05, 0.05]))

    /// Ice: frost at rest, glacial blue into periwinkle while working, pale gold, then rose.
    public static let glacier = OrbPalette(
        idle: s([0.72, 0.86, 1], [0.45, 0.6, 0.8], [0.92, 0.97, 1], [0.15, 0.25, 0.4]),
        working: s([0.4, 0.8, 1], [0.55, 0.55, 1], [0.88, 0.97, 1], [0.1, 0.28, 0.55]),
        needs: s([1, 0.93, 0.6], [0.85, 0.75, 0.5], [1, 1, 0.88], [0.4, 0.35, 0.15]),
        error: s([1, 0.45, 0.6], [0.7, 0.2, 0.4], [1, 0.75, 0.85], [0.45, 0.1, 0.22]))

    /// Fire: smouldering coals at rest, flame while working, white heat when it needs you, and a cold blue error.
    public static let ember = OrbPalette(
        idle: s([0.75, 0.35, 0.2], [0.4, 0.12, 0.08], [0.95, 0.6, 0.4], [0.28, 0.06, 0.02]),
        working: s([1, 0.6, 0.15], [0.9, 0.2, 0.05], [1, 0.9, 0.5], [0.55, 0.15, 0.02]),
        needs: s([1, 0.97, 0.7], [1, 0.75, 0.35], [1, 1, 0.92], [0.5, 0.4, 0.15]),
        error: s([0.35, 0.6, 1], [0.15, 0.25, 0.75], [0.7, 0.85, 1], [0.05, 0.12, 0.45]))

    /// Pastels: lilac at rest, bubblegum and mint while working, lemon, then cherry.
    public static let candy = OrbPalette(
        idle: s([0.85, 0.75, 1], [0.6, 0.5, 0.85], [0.97, 0.92, 1], [0.35, 0.25, 0.5]),
        working: s([1, 0.42, 0.75], [0.35, 0.9, 0.8], [0.6, 1, 0.88], [0.42, 0.12, 0.35]),
        needs: s([1, 0.95, 0.5], [0.95, 0.75, 0.45], [1, 1, 0.82], [0.45, 0.4, 0.12]),
        error: s([1, 0.3, 0.42], [0.8, 0.1, 0.3], [1, 0.65, 0.72], [0.48, 0.05, 0.15]))

    /// Regal: deep purple at rest, gold over violet while working, turquoise when it needs you, ruby for errors.
    public static let royal = OrbPalette(
        idle: s([0.55, 0.38, 0.85], [0.3, 0.15, 0.55], [0.78, 0.65, 1], [0.18, 0.06, 0.38]),
        working: s([1, 0.78, 0.22], [0.48, 0.15, 0.85], [1, 0.85, 0.35], [0.32, 0.1, 0.48]),
        needs: s([0.3, 0.95, 0.85], [0.1, 0.55, 0.6], [0.75, 1, 0.95], [0.04, 0.32, 0.3]),
        error: s([0.95, 0.15, 0.35], [0.5, 0.02, 0.2], [1, 0.55, 0.65], [0.42, 0.02, 0.1]))

    /// Woodland: moss at rest, fern into teal while working, autumn orange, then berry.
    public static let forest = OrbPalette(
        idle: s([0.5, 0.68, 0.38], [0.25, 0.4, 0.2], [0.75, 0.88, 0.6], [0.1, 0.22, 0.06]),
        working: s([0.4, 0.95, 0.5], [0.15, 0.55, 0.45], [0.8, 1, 0.7], [0.08, 0.3, 0.12]),
        needs: s([1, 0.6, 0.2], [0.75, 0.32, 0.08], [1, 0.82, 0.5], [0.45, 0.18, 0.02]),
        error: s([0.85, 0.15, 0.4], [0.45, 0.02, 0.25], [1, 0.5, 0.65], [0.38, 0.02, 0.15]))

    /// Rose gold: blush at rest, rose and copper while working, champagne, then deep red.
    public static let roseGold = OrbPalette(
        idle: s([0.92, 0.72, 0.76], [0.6, 0.42, 0.48], [1, 0.9, 0.92], [0.35, 0.18, 0.22]),
        working: s([1, 0.55, 0.45], [0.75, 0.28, 0.42], [1, 0.72, 0.55], [0.45, 0.14, 0.16]),
        needs: s([1, 0.88, 0.6], [0.85, 0.65, 0.4], [1, 0.97, 0.85], [0.42, 0.3, 0.12]),
        error: s([0.82, 0.08, 0.18], [0.45, 0.02, 0.12], [1, 0.45, 0.5], [0.38, 0.01, 0.06]))

    public static let presets: [(name: String, palette: OrbPalette)] = [
        ("Agents view", agentsView), ("Original design", originalDesign), ("Blue", blue),
        ("Aurora", aurora), ("Ocean", ocean), ("Sunset", sunset), ("Synthwave", synthwave), ("Matrix", matrix),
        ("Mono", mono), ("Glacier", glacier), ("Ember", ember), ("Candy", candy), ("Royal", royal),
        ("Forest", forest), ("Rose Gold", roseGold)
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
