/// Per-state orb look. Motion and the working/error palettes come from PAL.claude + MOTION in the design's
/// orbParticles.js; idle (green) and needs (yellow) are recoloured to match Claude Code's agents view.
public struct OrbParams: Equatable, Sendable {
    public var c1, c2, c3, halo: SIMD3<Float>
    public var energy, wave, glow, bright, ring, scale, glitch: Float

    public init(c1: SIMD3<Float>, c2: SIMD3<Float>, c3: SIMD3<Float>, halo: SIMD3<Float>,
                energy: Float, wave: Float, glow: Float, bright: Float, ring: Float, scale: Float, glitch: Float) {
        self.c1 = c1; self.c2 = c2; self.c3 = c3; self.halo = halo
        self.energy = energy; self.wave = wave; self.glow = glow; self.bright = bright
        self.ring = ring; self.scale = scale; self.glitch = glitch
    }

    public static func target(for state: BubbleState) -> OrbParams {
        switch state {
        case .idle:
            OrbParams(c1: [0.42, 0.88, 0.56], c2: [0.22, 0.62, 0.4], c3: [0.72, 0.96, 0.78], halo: [0.06, 0.3, 0.14],
                      energy: 0.12, wave: 0.08, glow: 0.35, bright: 0.5, ring: 0.35, scale: 0.72, glitch: 0)
        case .working:
            OrbParams(c1: [1, 0.46, 0.2], c2: [0.56, 0.3, 1], c3: [1, 0.45, 0.72], halo: [0.3, 0.14, 0.75],
                      energy: 1, wave: 1, glow: 1, bright: 1, ring: 1, scale: 1, glitch: 0)
        case .needs:
            OrbParams(c1: [1, 0.86, 0.24], c2: [1, 0.66, 0.12], c3: [1, 0.95, 0.62], halo: [0.55, 0.4, 0.04],
                      energy: 0.22, wave: 0.18, glow: 0.85, bright: 0.75, ring: 0.9, scale: 1, glitch: 0)
        case .error:
            OrbParams(c1: [1, 0.2, 0.22], c2: [0.72, 0.08, 0.2], c3: [1, 0.55, 0.45], halo: [0.5, 0.03, 0.06],
                      energy: 0.08, wave: 0, glow: 0.75, bright: 0.8, ring: 0.85, scale: 0.9, glitch: 1)
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
    /// One flat color that reads like the orb at a glance (pips, menu icons). Working's first palette
    /// entry is orange, but the orb reads violet, so it uses the violet entry instead.
    public var swatch: SIMD3<Float> {
        let p = OrbParams.target(for: self)
        return self == .working ? p.c2 : p.c1
    }
}
