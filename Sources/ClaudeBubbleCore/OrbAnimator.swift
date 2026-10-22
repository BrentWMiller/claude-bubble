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
    /// Work motions (design: Orb States): blending from `workA` to `workB` by `workMix` (shader mode numbers).
    public var workA: Float = 0
    public var workB: Float = 0
    public var workMix: Float = 1
    /// Bash: 0 at a full boil, toward 1 as the command settles to a simmer.
    public var settle: Float = 0
    /// Subagents running (eased), for the interference layer.
    public var sub: Float = 0
    /// Seconds since a tool failed / a skill started, or -1.
    public var failAge: Float = -1
    public var skillAge: Float = -1
    /// Up to three tool-complete ticks: their ages (-1 = none) and amplitudes.
    public var tickAges = SIMD3<Float>(-1, -1, -1)
    public var tickAmps = SIMD3<Float>(0, 0, 0)
    /// Voice (design: Talking Orb): loudness 0…1 (eased), the ripples' phase, and 1 while it's the user talking.
    public var voice: Float = 0
    public var voicePhase: Float = 0
    public var listening: Float = 0
    /// The voice's low, mid and high bands (eased).
    public var voiceBands = SIMD3<Float>(0, 0, 0)
    /// Colour fan: 0…1 while new colours sweep out from the top of the orb (-1 when settled), and the colours it
    /// sweeps away from. `params` holds the colours it sweeps to.
    public var fan: Float = -1
    public var fanFrom = OrbParams.target(for: .idle)
}

/// Port of OrbBase.stepCommon + OrbP.step from the design's JS.
/// What the orb hears while you talk with a session: loudness and three bands, each about 0…1, whether it's you
/// (listening) or Claude (speaking), and whose colours to wear (the session's, as its row shows them).
public struct VoiceLevels: Equatable, Sendable {
    public var level, low, mid, high: Float
    public var listening: Bool
    public var look: BubbleState

    public init(level: Float = 0, low: Float = 0, mid: Float = 0, high: Float = 0, listening: Bool,
                look: BubbleState = .working) {
        self.level = level; self.low = low; self.mid = mid; self.high = high; self.listening = listening; self.look = look
    }
}

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
    /// Colour changes (state or palette) fan out over this long instead of crossfading.
    public static let fanDuration: Float = 1.4
    private var fanTime: Float?
    private var fanFrom = OrbParams.target(for: .idle)
    private var colorKey: (state: BubbleState, palette: OrbPalette)
    /// What the orb looked like last frame (mid-fan, the blend so far), for a fan that starts mid-fan.
    private var lastShown: OrbParams?
    /// What Claude is doing (used while working); the director paces the changes.
    public var motion: Motion = .generating
    /// Quiet mode: the orb eases down to a small dot with a calmer glow.
    public var quiet = false
    /// The scale quiet shrinks the orb to (OrbSize.quietScale: the island orb's size).
    public var quietScale: Float = 0.28

    /// Jumps straight to quiet's size (or back to full), for an orb that's only now appearing.
    public func settleQuiet() { quietness = quiet ? 1 : 0 }
    private var quietness: Float = 0
    /// Seconds the current motion has run (bash settles with it).
    public var motionElapsed: Double = 0
    public var subagents = 0
    /// A conversation with a session (nil when there's none): the orb takes the voice look and moves with the words.
    public var voice: VoiceLevels?
    private var vox: Float = 0
    private var voxBands = SIMD3<Float>(0, 0, 0)
    private var listen: Float = 0
    private var voxPhase: Float = 0
    private let director = MotionDirector()
    private var settle: Float = 0
    private var sub: Float = 0
    private var ticks: [(at: Double, amp: Float)] = []
    private var tickHistory: [Double] = []
    private var failAt: Double?
    private var skillAt: Double?
    private var pointerTarget: (offset: SIMD2<Float>, closeness: Float) = (.zero, 0)
    private var pointerOffset = SIMD2<Float>(0, 0)
    private var pointerVelocity = SIMD2<Float>(0, 0)
    private var closeness: Float = 0
    private var closenessVelocity: Float = 0
    /// Time since working → idle (the completed moment), in sequence seconds; nil when not playing.
    private var completionTime: Float?
    /// The completed moment plays at half the design's speed (8s instead of 4s), so it's easy to take in.
    public static let completionSpeed: Float = 0.5
    /// "All done" green the orb washes into on the release by default (the palette's `done` sets it).
    public static let doneGreen = OrbPalette.defaultDone
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
        colorKey = (state, palette)
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

    /// A tool call finished: a small ring. Bursts get quieter (down to 30%), and at most three show at once.
    public func tick() {
        guard state == .working else { return }
        ticks.removeAll { time - $0.at >= 0.8 }
        tickHistory.removeAll { time - $0 >= 1.5 }
        tickHistory.append(time)
        ticks.append((time, max(0.3, 1 / (1 + 0.35 * Float(tickHistory.count - 1)))))
        if ticks.count > 3 { ticks.removeFirst() }
    }

    /// A tool call failed: a dent and a small jolt.
    public func fail() {
        guard state == .working else { return }
        failAt = time
        shake = max(shake, 0.3)
    }

    /// A skill or plan started: a sweep of light and a quick spin.
    public func skill() {
        guard state == .working else { return }
        skillAt = time
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
    /// Holds the all-done wash (previewing its colour while it's being edited).
    public var showsDone = false

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
        let talking = voice != nil
        let shown: BubbleState = voice?.look ?? ((completionTime.map { $0 < 0.42 } ?? false) ? heldState : state)
        let target = voice.map { OrbParams.voice(palette: palette, look: $0.look) } ?? OrbParams.target(for: shown, palette: palette)
        if shown != colorKey.state || palette != colorKey.palette {
            // New colours: fan them out from what's showing, rather than crossfading the whole orb.
            colorKey = (shown, palette)
            fanFrom = lastShown ?? current
            fanTime = 0
            current.c1 = target.c1; current.c2 = target.c2; current.c3 = target.c3; current.halo = target.halo
        }
        current = current.approached(target, k: k)
        tintGate += ((shown == .working || shown == .idle ? 1 : 0) - tintGate) * k
        director.update(want: shown == .working && !talking ? motion : .generating, now: time)
        let settleTarget = Float(1 - exp(-max(motionElapsed, 0) / 6))
        // A new command drops straight back to a boil; otherwise ease.
        settle = settleTarget < settle - 0.3 ? settleTarget : settle + (settleTarget - settle) * (1 - powf(0.2, dt))
        // Layers belong to the working look (not a forced state or a pip preview).
        sub += (shown == .working && !talking ? Float(min(max(subagents, 0), 6)) - sub : -sub) * (1 - powf(0.06, dt))
        if let s = skillAt {
            let age = Float(time - s)
            if age < 1.4 { phase += dt * 1.2 * sinf(.pi * min(1, age / 1.4)) }
        }
        bounceVelocity += (-bounce * 220 - bounceVelocity * 14) * dt
        bounce += bounceVelocity * dt
        let tint = usageLeft.map(UsageTint.amounts(left:)) ?? (warm: 0, critical: 0)
        let tintK = 1 - expf(-dt / 0.6)
        usageWarm += (tint.warm - usageWarm) * tintK
        usageCritical += (tint.critical - usageCritical) * tintK
        lowUsage += ((usageLeft.map { $0 <= 10 } ?? false ? 1 : 0) - lowUsage) * (1 - expf(-dt / 0.4))
        // Wrapping at 400π keeps floats precise without a visible seam, as long as every shader sin(k·phase) has k a
        // multiple of 0.005 and every fract(k·phase) has k·400π a whole number.
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
        quietness += ((quiet ? 1 : 0) - quietness) * (1 - expf(-dt / 0.25))
        var scale = current.scale * (1 + bounce) * here * (1 - 0.12 * lowUsage) * (1 - (1 - quietScale) * quietness)
        var glow = current.glow * min(here, 1) * (1 + 0.6 * flash) * (1 - 0.4 * lowUsage) * (1 - 0.5 * quietness)
        var ring = current.ring * (1 + 0.4 * flash)
        switch talking ? .working : state {
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
        // Voice (design: Talking Orb): words swell in fast and fade slowly; the ripples run out while Claude speaks and
        // in while you do. Phase wraps like the main one (its shader multiples are 1, 1.3 and 2.1).
        let heard = min(max(voice?.level ?? 0, 0), 1)
        vox += (heard - vox) * (1 - powf(heard > vox ? 0.00002 : 0.006, dt))
        let bands = voice.map { SIMD3($0.low, $0.mid, $0.high) } ?? .zero
        voxBands += (bands - voxBands) * (1 - powf(0.0005, dt))
        let you: Float = voice?.listening == true ? 1 : 0
        listen += (you - listen) * (1 - powf(0.03, dt))
        voxPhase = (voxPhase + dt * (2 + vox * 10) * (you > 0 ? -1 : 1)).truncatingRemainder(dividingBy: 400 * .pi)
        glow *= 1 + vox * 0.7
        let attention = interaction == .attention ? closeness : 0
        if interaction == .attention { glow *= 1 + 0.2 * closeness }
        let shakeX = shake > 0.01 ? Float(sin(time * 70)) * shake * 0.04 : 0
        // All done: wash into green on the release, hold, then fade back to the palette's rest colours.
        var output = UsageTint.blend(current, palette: palette, warm: usageWarm * tintGate, critical: usageCritical * tintGate)
        let washed = showsDone ? 1 : completionTime.map { bt in Self.smoothstep(0.42, 0.55, bt) * (1 - Self.smoothstep(1.0, 2.25, bt)) }
        if let w = washed {
            let g = palette.done
            output.c1 += (g.c1 - output.c1) * w
            output.c2 += (g.c2 - output.c2) * w
            output.c3 += (g.c3 - output.c3) * w
            output.halo += (g.halo - output.halo) * w
        }
        var fanProgress: Float = -1
        if let t = fanTime {
            let next = t + dt
            if next < Self.fanDuration { fanTime = next; fanProgress = next / Self.fanDuration } else { fanTime = nil }
        }
        // Mid-fan the orb shows roughly the blend so far (the sweep covers about that share of it).
        if fanProgress >= 0 {
            var shownNow = output
            let p = fanProgress
            shownNow.c1 = fanFrom.c1 + (output.c1 - fanFrom.c1) * p
            shownNow.c2 = fanFrom.c2 + (output.c2 - fanFrom.c2) * p
            shownNow.c3 = fanFrom.c3 + (output.c3 - fanFrom.c3) * p
            shownNow.halo = fanFrom.halo + (output.halo - fanFrom.halo) * p
            lastShown = shownNow
        } else {
            lastShown = output
        }
        var frame = OrbFrame(params: output, phase: phase, scale: scale, glow: glow, ring: ring, shakeX: shakeX,
                             pointer: pointerOffset, attention: attention, completion: completion, pop: pop,
                             pull: pull, pullAngle: pullAngle)
        let work = director.frame(now: time)
        frame.fan = fanProgress
        frame.fanFrom = fanFrom
        frame.workA = work.from.shaderMode
        frame.workB = work.to.shaderMode
        frame.workMix = work.mix
        frame.settle = settle
        frame.sub = sub
        frame.voice = vox
        frame.voicePhase = voxPhase
        frame.listening = listen
        frame.voiceBands = voxBands
        if let f = failAt { if time - f < 1.2 { frame.failAge = Float(time - f) } else { failAt = nil } }
        if let s = skillAt { if time - s < 1.6 { frame.skillAge = Float(time - s) } else { skillAt = nil } }
        ticks.removeAll { time - $0.at >= 0.8 }
        for (i, t) in ticks.enumerated() {
            frame.tickAges[i] = Float(time - t.at)
            frame.tickAmps[i] = t.amp
        }
        return frame
    }

    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
