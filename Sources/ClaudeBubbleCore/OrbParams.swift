/// Per-state orb look: motion from MOTION in the design's orbParticles.js, colors from an `OrbPalette`.
public struct OrbParams: Equatable, Sendable {
    public var c1, c2, c3, halo: SIMD3<Float>
    public var energy, wave, glow, bright, ring, scale, glitch: Float

    public init(c1: SIMD3<Float>, c2: SIMD3<Float>, c3: SIMD3<Float>, halo: SIMD3<Float>,
                energy: Float, wave: Float, glow: Float, bright: Float, ring: Float, scale: Float, glitch: Float) {
        self.c1 = c1; self.c2 = c2; self.c3 = c3; self.halo = halo
        self.energy = energy; self.wave = wave; self.glow = glow; self.bright = bright
        self.ring = ring; self.scale = scale; self.glitch = glitch
    }

    /// Motion per state (from MOTION in the design's orbParticles.js); colors come from the palette.
    public static func target(for state: BubbleState, palette: OrbPalette = .agentsView) -> OrbParams {
        let c = palette[state]
        func make(_ energy: Float, _ wave: Float, _ glow: Float, _ bright: Float, _ ring: Float, _ scale: Float, _ glitch: Float) -> OrbParams {
            OrbParams(c1: c.c1, c2: c.c2, c3: c.c3, halo: c.halo,
                      energy: energy, wave: wave, glow: glow, bright: bright, ring: ring, scale: scale, glitch: glitch)
        }
        switch state {
        case .idle: return make(0.12, 0.08, 0.8, 0.62, 0.95, 0.72, 0)   // glowy rest: bright rim, soft wide halo
        case .working: return make(1, 1, 1, 1, 1, 1, 0)
        case .needs: return make(0.22, 0.18, 0.85, 0.75, 0.9, 1, 0)
        case .error: return make(0.08, 0, 0.75, 0.8, 0.85, 0.9, 1)
        }
    }

    /// Moves every value a fraction `k` of the way toward `t`.
    public func approached(_ t: OrbParams, k: Float) -> OrbParams {
        func m(_ a: Float, _ b: Float) -> Float { a + (b - a) * k }
        func m(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * k }
        return OrbParams(c1: m(c1, t.c1), c2: m(c2, t.c2), c3: m(c3, t.c3), halo: m(halo, t.halo),
                         energy: m(energy, t.energy), wave: m(wave, t.wave), glow: m(glow, t.glow),
                         bright: m(bright, t.bright), ring: m(ring, t.ring), scale: m(scale, t.scale),
                         glitch: m(glitch, t.glitch))
    }
}

extension BubbleState {
    /// The default (Agents view) pip color; the app uses its live palette's swatch.
    public var swatch: SIMD3<Float> { OrbPalette.agentsView[self].swatch }
}
