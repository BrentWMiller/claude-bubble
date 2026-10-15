import Foundation

/// One sound to play: what, at which note, and where in the stereo field.
public struct SoundRequest: Equatable, Sendable {
    public let cue: PipSounds.Cue
    /// MIDI note of the pip's slot.
    public let note: Int
    /// −1 (left) … 1 (right).
    public let pan: Float
    /// Where a slide ends up.
    public let endPan: Float
    /// Notes of every pip, for the all-done chord.
    public let chord: [Int]

    public init(cue: PipSounds.Cue, note: Int, pan: Float, endPan: Float = 0, chord: [Int] = []) {
        self.cue = cue
        self.note = note
        self.pan = pan
        self.endPan = endPan
        self.chord = chord
    }
}

/// Pip sounds from the design's Pip Sounds exploration: every pip owns a note (its slot on a C-major pentatonic
/// scale, panned by its place on the arc), every change gets a small sound, finishing everything plays a chord.
public enum PipSounds {
    public enum Cue: String, CaseIterable, Sendable {
        case spawn, needs, error, finish, slide, merge, resume, hover, remove
    }

    public static let pentatonic = [64, 67, 69, 72, 74, 76, 79]

    public static func note(slot: Int) -> Int {
        pentatonic[min(max(slot, 0), pentatonic.count - 1)]
    }

    /// The pip's horizontal place on the arc, as stereo pan.
    public static func pan(slot: Int, slots: Int) -> Float {
        let degrees = 90 - (Double(min(slot, 6)) - Double(max(min(slots, 7), 1) - 1) / 2) * PipArc.stepDegrees
        return Float(max(-1, min(1, cos(degrees * .pi / 180) * 1.4)))
    }

    /// The sounds for a batch of choreographer events. `previous` is the frame before them (for removed pips).
    public static func requests(for events: [PipEvent], frame: PipsFrame, previous: PipsFrame) -> [SoundRequest] {
        func place(_ id: String) -> (slot: Int, slots: Int) {
            for f in [frame, previous] {
                if let pip = f.pips.first(where: { $0.id == id }) {
                    return (pip.slot ?? min(pip.rank, 6), max(f.slots, 1))
                }
            }
            return (3, 7)
        }
        func request(_ cue: Cue, _ id: String) -> SoundRequest {
            let (slot, slots) = place(id)
            let end = cue == .slide ? pan(slot: slots - 1, slots: slots) : 0
            return SoundRequest(cue: cue, note: note(slot: slot), pan: pan(slot: slot, slots: slots), endPan: end)
        }
        return events.compactMap { event in
            switch event {
            case let .spawned(id): request(.spawn, id)
            case let .needs(id): request(.needs, id)
            case let .error(id): request(.error, id)
            case let .finished(id): request(.finish, id)
            case let .retired(id): request(.slide, id)
            case let .resumed(id): request(.resume, id)
            case let .removed(id): request(.remove, id)
            case .allDone:
                SoundRequest(cue: .merge, note: 72, pan: 0,
                             chord: frame.pips.sorted { $0.rank < $1.rank }.prefix(7).enumerated().map { note(slot: $0.offset) })
            case .ringPop: nil   // the finish sound covers it
            }
        }
    }
}

/// Rapid changes never pile up: each sound waits a moment before it can repeat.
public struct SoundRateLimiter {
    private var last: [PipSounds.Cue: Double] = [:]

    public init() {}

    public mutating func allow(_ cue: PipSounds.Cue, now: Double) -> Bool {
        let gap = cue == .hover ? 0.11 : 0.07
        if let previous = last[cue], now - previous < gap { return false }
        last[cue] = now
        return true
    }
}

/// Renders pip sounds offline, ported from the design's Web Audio code: detuned sine partials with soft attacks and
/// exponential decays, panned, sent to a small reverb, through a gentle low-pass and master gain.
public enum PipSynth {
    struct Partial {
        let ratio: Double, amp: Float, decay: Double
    }

    static let soft = [Partial(ratio: 1, amp: 1, decay: 1), Partial(ratio: 2, amp: 0.1, decay: 0.45)]
    static let glass = [Partial(ratio: 1, amp: 1, decay: 1), Partial(ratio: 2.76, amp: 0.05, decay: 0.3)]
    static let wood = [Partial(ratio: 1, amp: 1, decay: 1), Partial(ratio: 3.93, amp: 0.07, decay: 0.15)]
    static let pure = [Partial(ratio: 1, amp: 1, decay: 1)]

    struct Voice {
        var start: Double
        var freq: Double
        var glideTo: Double?
        var glideTime = 0.1
        var volume: Float = 0.1
        var decay = 1.4
        var attack = 0.006
        var pan: Float = 0
        var partials = soft
        var detuneCents: Double = 4
        var wet: Float = 1

        var end: Double { start + attack + decay * (partials.map(\.decay).max() ?? 1) * 1.3 + 0.05 }
    }

    static func hz(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    final class Mix {
        var dryL, dryR, wetL, wetR: [Float]
        init(count: Int) {
            dryL = [Float](repeating: 0, count: count)
            dryR = dryL; wetL = dryL; wetR = dryL
        }
    }

    static func panGains(_ pan: Float) -> (Float, Float) {
        let x = (max(-1, min(1, pan)) + 1) / 2 * .pi / 2
        return (cos(x), sin(x))
    }

    static func add(_ v: Voice, to mix: Mix, sampleRate sr: Double) {
        let (gl, gr) = panGains(v.pan)
        let startIndex = Int(v.start * sr)
        for p in v.partials {
            let length = v.decay * p.decay
            let tau = length / 4.5
            let peak = v.volume * p.amp * 0.5
            let count = Int((v.attack + length * 1.3 + 0.05) * sr)
            for cents in [-v.detuneCents, v.detuneCents] {
                let detune = pow(2, cents / 1200)
                var phase = 0.0
                for i in 0..<count {
                    let index = startIndex + i
                    guard index < mix.dryL.count else { break }
                    let t = Double(i) / sr
                    var f = v.freq * p.ratio * detune
                    if let to = v.glideTo { f *= pow(to / v.freq, min(t / v.glideTime, 1)) }
                    phase += 2 * .pi * f / sr
                    let env = t < v.attack ? Double(peak) * t / v.attack : Double(peak) * exp(-(t - v.attack) / tau)
                    let s = Float(sin(phase) * env)
                    mix.dryL[index] += s * gl
                    mix.dryR[index] += s * gr
                    mix.wetL[index] += s * gl * v.wet
                    mix.wetR[index] += s * gr * v.wet
                }
            }
        }
    }

    /// RBJ biquad.
    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        mutating func set(lowpass: Bool, frequency f: Double, q: Double, sampleRate sr: Double) {
            let w = 2 * .pi * min(f, sr * 0.45) / sr, alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha
            if lowpass {
                b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0
            } else {
                b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0
            }
            a1 = -2 * c / a0; a2 = (1 - alpha) / a0
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// The retire slide: a soft filtered-noise swoosh that pans toward the end of the row.
    static func addSlide(_ r: SoundRequest, to mix: Mix, sampleRate sr: Double) {
        let duration = 0.42
        var hp = Biquad(), lp = Biquad()
        hp.set(lowpass: false, frequency: 280, q: 0.5, sampleRate: sr)
        var seed: UInt32 = 0x9E37_79B9
        for i in 0..<Int(duration * sr) where i < mix.dryL.count {
            let t = Double(i) / sr, x = t / duration
            if i % 32 == 0 {
                let cutoff = x < 0.45 ? 500 * pow(1300 / 500, x / 0.45) : 1300 * pow(600 / 1300, (x - 0.45) / 0.55)
                lp.set(lowpass: true, frequency: cutoff, q: 0.6, sampleRate: sr)
            }
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed) / Double(UInt32.max) * 2 - 1
            let gain = pow(sin(.pi * pow(x, 0.8)), 2) * 0.022
            let s = Float(lp.process(hp.process(noise)) * gain)
            let (gl, gr) = panGains(r.pan + (r.endPan - r.pan) * Float(x))
            mix.dryL[i] += s * gl; mix.dryR[i] += s * gr
            mix.wetL[i] += s * gl * 0.5; mix.wetR[i] += s * gr * 0.5
        }
    }

    static func voices(for r: SoundRequest) -> [Voice] {
        let n = r.note, pan = r.pan
        switch r.cue {
        case .spawn:
            return [Voice(start: 0, freq: hz(n - 5), glideTo: hz(n), glideTime: 0.1, volume: 0.075, decay: 0.55,
                          attack: 0.018, pan: pan, partials: soft, wet: 0.7)]
        case .needs:
            return [Voice(start: 0, freq: hz(n), volume: 0.085, decay: 0.9, attack: 0.012, pan: pan, partials: soft, wet: 0.8),
                    Voice(start: 0, freq: hz(n - 12), volume: 0.03, decay: 0.7, attack: 0.02, pan: pan, partials: pure,
                          detuneCents: 0, wet: 0.5),
                    Voice(start: 0.38, freq: hz(n + 3), volume: 0.085, decay: 1.1, attack: 0.012, pan: pan, partials: soft, wet: 0.8)]
        case .error:
            return [Voice(start: 0, freq: 110, glideTo: 72, glideTime: 0.1, volume: 0.13, decay: 0.22, attack: 0.008,
                          pan: pan, partials: pure, detuneCents: 0, wet: 0.2),
                    Voice(start: 0.05, freq: hz(n - 12), glideTo: hz(n - 15), glideTime: 0.16, volume: 0.065, decay: 0.55,
                          attack: 0.014, pan: pan, partials: soft, wet: 0.6)]
        case .resume:
            return [Voice(start: 0, freq: hz(n), volume: 0.035, decay: 0.3, attack: 0.004, pan: pan, partials: wood,
                          detuneCents: 0, wet: 0.4)]
        case .finish:
            return [Voice(start: 0, freq: hz(n + 7), volume: 0.075, decay: 1.2, attack: 0.01, pan: pan, partials: glass, wet: 0.9),
                    Voice(start: 0.02, freq: hz(n), volume: 0.03, decay: 1, attack: 0.02, pan: pan, partials: pure, wet: 0.8)]
        case .slide:
            return [Voice(start: 0.42 * 0.55, freq: hz(n + 12), volume: 0.012, decay: 0.35, attack: 0.02, pan: r.endPan,
                          partials: pure, detuneCents: 0, wet: 0.7)]
        case .hover:
            return [Voice(start: 0, freq: hz(n + 12), volume: 0.014, decay: 0.12, attack: 0.004, pan: pan, partials: wood,
                          detuneCents: 0, wet: 0.2)]
        case .remove:
            return [Voice(start: 0, freq: hz(n), glideTo: hz(n - 7), glideTime: 0.14, volume: 0.04, decay: 0.35,
                          attack: 0.012, pan: pan, partials: soft, wet: 0.6)]
        case .merge:
            let chord = r.chord.isEmpty ? [64, 67, 69] : r.chord
            let release = 0.42
            return chord.enumerated().map {
                Voice(start: Double($0.offset) * 0.05, freq: hz($0.element), volume: 0.038, decay: 1.6, attack: 0.02, partials: glass)
            } + [
                Voice(start: release, freq: 98, glideTo: 55, glideTime: 0.3, volume: 0.18, decay: 0.6, attack: 0.012,
                      partials: pure, detuneCents: 0, wet: 0.25),
                Voice(start: release, freq: hz(76), volume: 0.1, decay: 2, attack: 0.01, pan: -0.15, partials: glass),
                Voice(start: release + 0.1, freq: hz(83), volume: 0.08, decay: 2.2, attack: 0.01, pan: 0.15, partials: glass),
                Voice(start: release + 0.1, freq: hz(64), volume: 0.06, decay: 2.4, attack: 0.03, partials: soft)
            ]
        }
    }

    /// A small Schroeder reverb standing in for the design's convolver (1.5s tail, 18% wet).
    static func reverb(_ input: [Float], sampleRate sr: Double, spread: Double) -> [Float] {
        let combs = [0.0297, 0.0371, 0.0411, 0.0437].map { Int(($0 + spread) * sr) }
        var out = [Float](repeating: 0, count: input.count)
        for delay in combs {
            var buffer = [Float](repeating: 0, count: delay), index = 0, filtered: Float = 0
            for i in 0..<input.count {
                let y = buffer[index]
                filtered = y * 0.75 + filtered * 0.25
                buffer[index] = input[i] + filtered * 0.8
                index = (index + 1) % delay
                out[i] += y * 0.25
            }
        }
        for delay in [Int(0.005 * sr), Int(0.0017 * sr)] {
            var buffer = [Float](repeating: 0, count: max(delay, 1)), index = 0
            for i in 0..<out.count {
                let b = buffer[index], x = out[i]
                let y = -x * 0.5 + b
                buffer[index] = x + b * 0.5
                index = (index + 1) % buffer.count
                out[i] = y
            }
        }
        return out
    }

    public static func render(_ r: SoundRequest, sampleRate sr: Double) -> (left: [Float], right: [Float]) {
        let vs = voices(for: r)
        let length = max(vs.map(\.end).max() ?? 0, r.cue == .slide ? 0.42 : 0) + 1.2   // + reverb tail
        let mix = Mix(count: Int(length * sr))
        for v in vs { add(v, to: mix, sampleRate: sr) }
        if r.cue == .slide { addSlide(r, to: mix, sampleRate: sr) }
        let wetL = reverb(mix.wetL, sampleRate: sr, spread: 0)
        let wetR = reverb(mix.wetR, sampleRate: sr, spread: 0.0011)
        var lpL = Biquad(), lpR = Biquad()
        lpL.set(lowpass: true, frequency: 6000, q: 0.5, sampleRate: sr)
        lpR.set(lowpass: true, frequency: 6000, q: 0.5, sampleRate: sr)
        var left = [Float](repeating: 0, count: mix.dryL.count), right = left
        for i in 0..<left.count {
            left[i] = tanhf(Float(lpL.process(Double(mix.dryL[i] + wetL[i] * 0.18 * 2))) * 1.15)
            right[i] = tanhf(Float(lpR.process(Double(mix.dryR[i] + wetR[i] * 0.18 * 2))) * 1.15)
        }
        return (left, right)
    }
}
