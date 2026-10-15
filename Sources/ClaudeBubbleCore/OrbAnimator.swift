import Foundation

public struct OrbFrame: Sendable {
    public var params: OrbParams
    public var phase: Float
    public var scale: Float
    public var glow: Float
    public var ring: Float
    /// Horizontal shake offset as a fraction of the view width.
    public var shakeX: Float
    /// Angle (radians) from the orb's centre toward the pointer.
    public var pointerAngle: Float = 0
    /// 0…1 strength of the attention effect (highlight, tilt, directional glow).
    public var attention: Float = 0
}

/// Port of OrbBase.stepCommon + OrbP.step from the design's JS.
public final class OrbAnimator {
    public private(set) var state: BubbleState
    public private(set) var current: OrbParams
    /// Colors to ease toward; changing it fades the orb to the new palette.
    public var palette: OrbPalette = .agentsView
    public private(set) var bounce: Float = 0
    public private(set) var shake: Float = 0
    /// 0 = gone, 1 = fully here. Scales the whole orb for the materialize / pop-out animations.
    public private(set) var presence: Float = 1
    private var presenceTarget: Float = 1
    private var presenceVelocity: Float = 0
    /// A brief ring/glow brightening as the orb lands.
    private var flash: Float = 0
    public var interaction: PointerInteraction = .attention
    private var pointerTarget: (offset: SIMD2<Float>, closeness: Float) = (.zero, 0)
    private var pointerOffset = SIMD2<Float>(0, 0)
    private var pointerVelocity = SIMD2<Float>(0, 0)
    private var closeness: Float = 0
    private var closenessVelocity: Float = 0
    private var bounceVelocity: Float = 0
    private var phase: Float
    private var time: Double = 0
    private let random: () -> Float

    public init(state: BubbleState = .idle, palette: OrbPalette = .agentsView,
                random: @escaping () -> Float = { Float.random(in: 0..<1) }) {
        self.state = state
        self.palette = palette
        self.random = random
        current = .target(for: state, palette: palette)
        phase = random() * 20
        if state == .needs { bounce = -0.28 }
    }

    /// Grow from a point with a springy overshoot (startup, landing on a new display).
    public func appear() {
        presence = 0
        presenceVelocity = 0
        presenceTarget = 1
        flash = 1
    }

    /// Shrink to nothing quickly (leaving a display).
    public func vanish() {
        presenceTarget = 0
        presenceVelocity = 0
    }

    /// Where the pointer is relative to the orb; eased each step so the reaction never twitches.
    /// `offset` comes from `PointerProximity.offset` (length ≤ 1); `closeness` from `PointerProximity.closeness`.
    public func setPointer(offset: SIMD2<Float>, closeness: Float) {
        pointerTarget = (offset, min(max(closeness, 0), 1))
    }

    public var isVanished: Bool { presenceTarget == 0 && presence <= 0.001 }

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
        if presenceTarget > 0 {
            // Same spring as the needs bounce, so the motion family matches.
            presenceVelocity += ((presenceTarget - presence) * 220 - presenceVelocity * 14) * dt
            presence += presenceVelocity * dt
        } else {
            presence = max(0, presence - dt / 0.15)
        }
        flash *= powf(0.03, dt)
        // Critically damped springs: start from rest, glide, settle in ~1.3s with no overshoot or jolt.
        let w: Float = 5
        closenessVelocity += (w * w * (pointerTarget.closeness - closeness) - 2 * w * closenessVelocity) * dt
        closeness = min(max(closeness + closenessVelocity * dt, 0), 1)
        pointerVelocity += (w * w * (pointerTarget.offset - pointerOffset) - 2 * w * pointerVelocity) * dt
        pointerOffset += pointerVelocity * dt

        let here = max(0, presence)
        var scale = current.scale * (1 + bounce) * here
        var glow = current.glow * min(here, 1) * (1 + 0.6 * flash)
        var ring = current.ring * (1 + 0.4 * flash)
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
        // Directional effects scale with how far off-centre the pointer is, so they fade through the middle.
        let lean = closeness * min((pointerOffset * pointerOffset).sum().squareRoot(), 1)
        let attention = interaction == .attention ? lean : 0
        if interaction == .attention { glow *= 1 + 0.2 * closeness }
        let shakeX = shake > 0.01 ? Float(sin(time * 70)) * shake * 0.04 : 0
        return OrbFrame(params: current, phase: phase, scale: scale, glow: glow, ring: ring, shakeX: shakeX,
                        pointerAngle: atan2f(pointerOffset.y, pointerOffset.x), attention: attention)
    }
}
