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
    /// The rim's taffy pull toward a new pip: 0 at rest, 1 fully stretched, negative while wobbling back.
    public var pull: Float = 0
    /// Direction of the pull (radians, y-up).
    public var pullAngle: Float = 0
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
    /// Percent of the usage window left, or nil when usage is off / unknown. Warms the rim and glow below 50%,
    /// and under 10% the orb shrinks, slows and dims (low-usage mode). Both ease in; nothing flashes.
    public var usageLeft: Double?
    private var usageWarm: Float = 0
    private var usageCritical: Float = 0
    private var lowUsage: Float = 0
    /// 1 while the orb wears working/idle colours, eased like the colours so state changes hand off smoothly.
    private var tintGate: Float = 1
    private var pointerTarget: (offset: SIMD2<Float>, closeness: Float) = (.zero, 0)
    private var pointerOffset = SIMD2<Float>(0, 0)
    private var pointerVelocity = SIMD2<Float>(0, 0)
    private var closeness: Float = 0
    private var closenessVelocity: Float = 0
    /// Time since working → idle (the completed moment), in sequence seconds; nil when not playing.
    private var completionTime: Float?
    /// The completed moment plays at half the design's speed (8s instead of 4s), so it's easy to take in.
    public static let completionSpeed: Float = 0.5
    /// "All done" green the orb washes into on the release, whatever the palette (the design's success mint).
    public static let doneGreen = StateColors(c1: [0.74, 1, 0.84], c2: [0.5, 0.88, 0.7], c3: [0.9, 1, 0.92],
                                              halo: [0.1, 0.3, 0.18], swatch: [0.74, 1, 0.84])
    /// The look held through the gather (what the orb looked like when the celebration began).
    private var heldState: BubbleState = .working
    /// A ring pop's clock; nil when not playing.
    private var popTime: Float?
    private var pullTime: Float?
    private var pullAngle: Float = 0
    private var pullAmplitude: Float = 1
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
        tintGate = state == .working || state == .idle ? 1 : 0
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

    /// A new pip is born (design: Pip Sounds): the rim stretches toward `direction` (y-up) like taffy for 0.32s,
    /// the pip snaps off, and the rim wobbles back.
    /// `amplitude` < 1 for gentler pulls (a toast appearing uses 0.32).
    public func pull(towards direction: SIMD2<Float>, amplitude: Float = 1) {
        pullAngle = atan2f(direction.y, direction.x)
        pullAmplitude = amplitude
        pullTime = 0
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
        tintGate += ((shown == .working || shown == .idle ? 1 : 0) - tintGate) * k
        bounceVelocity += (-bounce * 220 - bounceVelocity * 14) * dt
        bounce += bounceVelocity * dt
        let tint = usageLeft.map(UsageTint.amounts(left:)) ?? (warm: 0, critical: 0)
        let tintK = 1 - expf(-dt / 0.6)
        usageWarm += (tint.warm - usageWarm) * tintK
        usageCritical += (tint.critical - usageCritical) * tintK
        lowUsage += ((usageLeft.map { $0 <= 10 } ?? false ? 1 : 0) - lowUsage) * (1 - expf(-dt / 0.4))
        // Every shader phase multiplier is a multiple of 0.05, so wrapping at 400π keeps floats precise without a visible seam.
        phase = (phase + dt * (0.2 + current.energy * 1.5) * (1 - 0.6 * lowUsage)).truncatingRemainder(dividingBy: 400 * .pi)
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
        var scale = current.scale * (1 + bounce) * here * (1 - 0.12 * lowUsage)
        var glow = current.glow * min(here, 1) * (1 + 0.6 * flash) * (1 - 0.4 * lowUsage)
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
        var pull: Float = 0
        if let t = pullTime {
            let pt = t + dt
            if pt < 0.32 {
                let x = pt / 0.32
                pull = x * x * (3 - 2 * x)
            } else {
                let l = pt - 0.32
                pull = expf(-l * 7) * cosf(l * 30)
            }
            pullTime = pt > 2 ? nil : pt
            pull = pullTime == nil ? 0 : pull * pullAmplitude
        }
        let attention = interaction == .attention ? closeness : 0
        if interaction == .attention { glow *= 1 + 0.2 * closeness }
        let shakeX = shake > 0.01 ? Float(sin(time * 70)) * shake * 0.04 : 0
        // All done: wash into green on the release, hold, then fade back to the palette's rest colours.
        var output = UsageTint.blend(current, palette: palette, warm: usageWarm * tintGate, critical: usageCritical * tintGate)
        if let bt = completionTime {
            let w = Self.smoothstep(0.42, 0.55, bt) * (1 - Self.smoothstep(1.0, 2.25, bt))
            let g = Self.doneGreen
            output.c1 += (g.c1 - output.c1) * w
            output.c2 += (g.c2 - output.c2) * w
            output.c3 += (g.c3 - output.c3) * w
            output.halo += (g.halo - output.halo) * w
        }
        return OrbFrame(params: output, phase: phase, scale: scale, glow: glow, ring: ring, shakeX: shakeX,
                        pointer: pointerOffset, attention: attention, completion: completion, pop: pop,
                        pull: pull, pullAngle: pullAngle)
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
