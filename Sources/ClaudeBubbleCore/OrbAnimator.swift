import Foundation

public struct OrbFrame: Sendable {
    public var params: OrbParams
    public var phase: Float
    public var scale: Float
    public var glow: Float
    public var ring: Float
    /// Horizontal shake offset as a fraction of the view width.
    public var shakeX: Float
    /// Where the pointer's light sits over the orb, in radii (length ≤ ~1; zero = front centre).
    public var pointer = SIMD2<Float>(0, 0)
    /// 0…1 strength of the attention effect.
    public var attention: Float = 0
    /// Seconds into the "session complete" sequence, or -1 when it isn't playing.
    public var completion: Float = -1
    /// Seconds into a ring pop (one session finished while others carry on), or -1.
    public var pop: Float = -1
    /// Seconds into the orb dripping out a new pip, or -1.
    public var emit: Float = -1
    /// Where the new pip sits, in orb radii from the centre (y-up): the drip travels there.
    public var emitTarget = SIMD2<Float>(0, -1.28)
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
    /// Time since working → idle (the completed moment), in sequence seconds; nil when not playing.
    private var completionTime: Float?
    /// The completed moment plays at half the design's speed (8s instead of 4s), so it's easy to take in.
    public static let completionSpeed: Float = 0.5
    /// The look held through the gather (what the orb looked like when the celebration began).
    private var heldState: BubbleState = .working
    /// A ring pop's clock; nil when not playing.
    private var popTime: Float?
    private var emitTime: Float?
    private var emitTarget = SIMD2<Float>(0, -1.28)
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

    /// One session finished while others are still busy: a single chromatic ring and a sheen.
    public func ringPop() {
        popTime = 0
    }

    /// A new pip is born: a droplet of the orb's own dots swells at the tip facing `target`, pinches off,
    /// travels to it and condenses into the pip, while the orb heals. `target` is in orb radii (y-up).
    public func emit(to target: SIMD2<Float>) {
        emitTarget = target
        emitTime = 0
    }

    /// Everything finished: play the completed moment, holding `held`'s look until the release.
    /// Changing state never celebrates on its own; the caller decides (the pips' all-done merge, or Debug).
    public func celebrate(from held: BubbleState) {
        heldState = held
        completionTime = 0
    }

    public func setState(_ new: BubbleState) {
        guard new != state else { return }
        // New activity cancels a celebration in progress.
        if new != .idle { completionTime = nil }
        if new == .needs { bounce = -0.28; bounceVelocity = 0 }
        if new == .error { shake = 1 }
        state = new
    }

    public func step(dt rawDt: Double) -> OrbFrame {
        let dt = Float(min(max(rawDt, 0), 0.05))
        time += Double(dt)
        let k = 1 - powf(0.02, dt)
        if let t = completionTime { completionTime = t + dt * Self.completionSpeed }
        // The orb keeps the look it celebrates from through the gather, and turns to rest on the release (0.42s).
        let shown: BubbleState = (completionTime.map { $0 < 0.42 } ?? false) ? heldState : state
        current = current.approached(.target(for: shown, palette: palette), k: k)
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
            // The rest breath fades in as the completed moment winds down.
            // (blended from neutral, so neither the swing nor the dimmer baseline cuts into the celebration).
            let calm = completionTime.map { Self.smoothstep(2.25, 4, $0) } ?? 1
            let b = Float(sin(time * .pi / 2))
            scale *= 1 + 0.05 * b * calm
            glow *= 1 + calm * (-0.3 + 0.3 * b)
            ring *= 1 + calm * (-0.25 + 0.25 * b)
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
        // Completed moment (from the design's Completed Moment exploration): gather, springy release, glow bloom.
        var completion: Float = -1
        if let bt = completionTime {
            let gather = Self.smoothstep(0, 0.38, bt) * (1 - Self.smoothstep(0.38, 0.46, bt))
            let l = max(bt - 0.42, 0)
            let released: Float = bt > 0.42 ? 1 : 0
            scale *= 1 - 0.06 * gather + released * 0.07 * expf(-l * 4.5) * sinf(l * 13 + 0.2)
            glow *= 1 + 1.6 * gather + released * 2.2 * expf(-l * 1.6)
            ring *= 1 + 0.8 * gather
            phase += dt * Self.completionSpeed * (2.5 * gather + released * 2 * expf(-l * 2))
            if bt < 4 { completion = bt } else { completionTime = nil }
        }
        var pop: Float = -1
        if let t = popTime {
            let next = t + dt
            if next < 1.6 { popTime = next; pop = next } else { popTime = nil }
        }
        var emit: Float = -1
        if let t = emitTime {
            let next = t + dt
            if next < 1.2 { emitTime = next; emit = next } else { emitTime = nil }
        }
        let attention = interaction == .attention ? closeness : 0
        if interaction == .attention { glow *= 1 + 0.2 * closeness }
        let shakeX = shake > 0.01 ? Float(sin(time * 70)) * shake * 0.04 : 0
        return OrbFrame(params: current, phase: phase, scale: scale, glow: glow, ring: ring, shakeX: shakeX,
                        pointer: pointerOffset, attention: attention, completion: completion, pop: pop,
                        emit: emit, emitTarget: emitTarget)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
