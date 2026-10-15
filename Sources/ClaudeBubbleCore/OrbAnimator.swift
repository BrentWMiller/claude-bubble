import Foundation

public struct OrbFrame: Sendable {
    public var params: OrbParams
    public var phase: Float
    public var scale: Float
    public var glow: Float
    public var ring: Float
    /// Horizontal shake offset as a fraction of the view width.
    public var shakeX: Float
}

/// Port of OrbBase.stepCommon + OrbP.step from the design's JS.
public final class OrbAnimator {
    public private(set) var state: BubbleState
    public private(set) var current: OrbParams
    /// Colors to ease toward; changing it fades the orb to the new palette.
    public var palette: OrbPalette = .agentsView
    public private(set) var bounce: Float = 0
    public private(set) var shake: Float = 0
    private var bounceVelocity: Float = 0
    private var phase: Float
    private var time: Double = 0
    private let random: () -> Float

    public init(state: BubbleState = .idle, random: @escaping () -> Float = { Float.random(in: 0..<1) }) {
        self.state = state
        self.random = random
        current = .target(for: state)
        phase = random() * 20
        if state == .needs { bounce = -0.28 }
    }

    public func setState(_ new: BubbleState) {
        guard new != state else { return }
        if new == .needs { bounce = -0.28; bounceVelocity = 0 }
        if new == .error { shake = 1 }
        state = new
    }

    public func step(dt rawDt: Double) -> OrbFrame {
        let dt = Float(min(max(rawDt, 0), 0.05))
        time += Double(dt)
        let k = 1 - powf(0.02, dt)
        current = current.approached(.target(for: state, palette: palette), k: k)
        bounceVelocity += (-bounce * 220 - bounceVelocity * 14) * dt
        bounce += bounceVelocity * dt
        // Every shader phase multiplier is a multiple of 0.05, so wrapping at 400π keeps floats precise without a visible seam.
        phase = (phase + dt * (0.2 + current.energy * 1.5)).truncatingRemainder(dividingBy: 400 * .pi)
        shake *= powf(0.02, dt)

        var scale = current.scale * (1 + bounce)
        var glow = current.glow
        var ring = current.ring
        switch state {
        case .idle:
            let b = Float(sin(time * .pi / 2))
            scale *= 1 + 0.05 * b
            glow *= 0.7 + 0.3 * b
            ring *= 0.75 + 0.25 * b
        case .needs:
            let b = Float(sin(time * .pi / 1.4))
            glow *= 0.6 + 0.4 * b
            ring *= 0.8 + 0.2 * b
        case .error:
            if random() < 0.08 { ring *= 0.35 }
            glow *= 0.85 + 0.15 * Float(sin(time * 9))
        case .working:
            break
        }
        let shakeX = shake > 0.01 ? Float(sin(time * 70)) * shake * 0.04 : 0
        return OrbFrame(params: current, phase: phase, scale: scale, glow: glow, ring: ring, shakeX: shakeX)
    }
}
