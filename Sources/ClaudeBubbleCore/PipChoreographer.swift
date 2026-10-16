import CoreGraphics
import Foundation

public struct PipInput: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    /// Finished with an open pull request ("Ready for review").
    public let review: Bool
    public init(id: String, state: BubbleState, review: Bool = false) {
        self.id = id
        self.state = state
        self.review = review
    }
}

public enum PipEvent: Equatable, Sendable {
    /// One session finished while others are still active.
    case ringPop
    /// A new session's pip is being drawn out of the orb.
    case spawned(String)
    /// Every session has finished (the pips merge): the orb's full celebration.
    case allDone
    /// Per-session transitions (for sounds).
    case needs(String)
    case error(String)
    case finished(String)
    /// A finished pip slides to the end of the row (after its flare).
    case retired(String)
    /// A session went back to work.
    case resumed(String)
    case removed(String)
    /// A finished session opened a pull request after finishing: "Ready for review".
    case reviewReady(String)
}

public struct PipFrame: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    /// Position on the arc, or nil when collapsed into +N.
    public let slot: Int?
    /// Sort position (also the merge stagger order).
    public let rank: Int
    /// Merged into the orb: drawn at its centre.
    public let atCenter: Bool
    /// Just spawned: hidden while the orb's rim stretches toward its slot.
    public let pulling: Bool
    /// The moment it pinches off: drawn as a stretched droplet near the rim, then springs round into its slot.
    public let snapping: Bool
    public let flaring: Bool
    public let hopping: Bool
    /// Sideways shake offset in points.
    public let shake: Double
    /// "Ready for review": drawn in the needs colour, first among the finished.
    public var review = false
}

public struct PipsFrame: Equatable, Sendable {
    public let pips: [PipFrame]
    public let slots: Int
    /// Sessions folded into the +N slot (0 when everything fits).
    public let overflow: Int
    /// Everything finished: the pips are pulled into the orb.
    public let merged: Bool
    /// Pips show only with 2+ sessions.
    public let visible: Bool

    public static let empty = PipsFrame(pips: [], slots: 0, overflow: 0, merged: false, visible: false)
}

/// Turns the session list into the design's pip choreography (Multi-session Pips exploration):
/// spawn from the centre, needs hops to the front, errors shake, finished pips flare then retire to the end,
/// and when everything is finished the pips merge into the orb. Deterministic in `now`.
public final class PipChoreographer {
    public static let maxSlots = 7
    public static let retireDelay = 0.65
    public static let mergeDelay = 0.9
    /// How long the rim stretches before the pip snaps off (matches the orb's pull).
    public static let pullDuration = 0.32
    /// How long the stretched droplet is shown before it springs round (about one tick).
    public static let snapDuration = 0.06
    static let hopWindows: [Range<Double>] = [0..<0.19, 0.38..<0.57]
    static let shakeSteps: [Double] = [5, -5, 4, -4, 2, -2, 0]
    static let shakeInterval = 0.055

    private struct Record {
        let id: String
        let order: Int
        var state: BubbleState
        /// The state used for ordering; lags `state` by the flare when a session finishes.
        var rankState: BubbleState
        let spawnedAt: Double
        var flareStart: Double?
        var retireAt: Double?
        var hopStart: Double?
        var shakeStart: Double?
        var review = false
    }

    private var records: [String: Record] = [:]
    private var nextOrder = 0
    private var mergeCheckAt: Double?
    public private(set) var merged = false
    /// A session finished since anything was last active, so the next merge is a real "all done".
    private var finishPending = false
    /// Events produced while advancing time, handed out by the next `update`.
    private var queued: [PipEvent] = []

    public init() {}

    /// Feed the current sessions; returns what the orb should react to.
    public func update(_ inputs: [PipInput], now: Double) -> [PipEvent] {
        advance(now)
        var events = queued
        queued = []
        let ids = Set(inputs.map(\.id))
        let gone = records.keys.filter { !ids.contains($0) }.sorted()
        if !gone.isEmpty {
            events += gone.map { .removed($0) }
            records = records.filter { ids.contains($0.key) }
            mergeCheckAt = now + Self.mergeDelay
        }
        for input in inputs {
            guard var rec = records[input.id] else {
                records[input.id] = Record(id: input.id, order: nextOrder, state: input.state, rankState: input.state,
                                           spawnedAt: now, review: input.review)
                nextOrder += 1
                events.append(.spawned(input.id))
                if input.state != .idle { merged = false; finishPending = false }
                mergeCheckAt = now + Self.mergeDelay
                continue
            }
            if rec.review != input.review {
                if input.review, rec.state == .idle, input.state == .idle { events.append(.reviewReady(input.id)) }
                rec.review = input.review
                records[input.id] = rec
            }
            guard rec.state != input.state else { continue }
            rec.state = input.state
            if input.state == .idle {
                rec.flareStart = now
                rec.retireAt = now + Self.retireDelay
                mergeCheckAt = now + Self.mergeDelay
                finishPending = true
                events.append(.finished(input.id))
                let othersActive = inputs.contains { $0.id != input.id && $0.state != .idle }
                if othersActive { events.append(.ringPop) }
            } else {
                rec.rankState = input.state
                rec.flareStart = nil
                rec.retireAt = nil
                rec.hopStart = input.state == .needs ? now : nil
                rec.shakeStart = input.state == .error ? now : nil
                merged = false
                finishPending = false
                switch input.state {
                case .needs: events.append(.needs(input.id))
                case .error: events.append(.error(input.id))
                case .working: events.append(.resumed(input.id))
                case .idle: break
                }
            }
            records[input.id] = rec
        }
        return events
    }

    public func frame(now: Double) -> PipsFrame {
        advance(now)
        // Like the agents view, "Ready for review" leads the finished group.
        let sorted = records.values.sorted {
            ($0.rankState.pipRank, $0.review ? 0 : 1, $0.order) < ($1.rankState.pipRank, $1.review ? 0 : 1, $1.order)
        }
        let n = sorted.count
        let over = n > Self.maxSlots
        let pips = sorted.enumerated().map { rank, rec -> PipFrame in
            let hop = rec.hopStart.map { start in Self.hopWindows.contains { $0.contains(now - start) } } ?? false
            var shake = 0.0
            if let start = rec.shakeStart {
                let step = Int((now - start) / Self.shakeInterval)
                if step >= 0, step < Self.shakeSteps.count { shake = Self.shakeSteps[step] }
            }
            return PipFrame(id: rec.id, state: rec.state,
                            slot: over && rank >= Self.maxSlots - 1 ? nil : rank,
                            rank: rank,
                            atCenter: merged,
                            pulling: !merged && now < rec.spawnedAt + Self.pullDuration,
                            snapping: !merged && now >= rec.spawnedAt + Self.pullDuration
                                && now < rec.spawnedAt + Self.pullDuration + Self.snapDuration,
                            flaring: rec.flareStart.map { now - $0 < Self.retireDelay } ?? false,
                            hopping: hop, shake: shake, review: rec.review && rec.state == .idle)
        }
        return PipsFrame(pips: pips, slots: over ? Self.maxSlots : n, overflow: over ? n - (Self.maxSlots - 1) : 0,
                         merged: merged, visible: n >= 2)
    }

    private func advance(_ now: Double) {
        for id in records.keys.sorted() {
            if let at = records[id]?.retireAt, now >= at {
                records[id]?.rankState = .idle
                records[id]?.retireAt = nil
                queued.append(.retired(id))
            }
        }
        if let at = mergeCheckAt, now >= at {
            mergeCheckAt = nil
            if !records.isEmpty, records.values.allSatisfy({ $0.state == .idle }) {
                if !merged, finishPending { queued.append(.allDone) }
                merged = true
                finishPending = false
            }
        }
    }
}

extension BubbleState {
    /// Pip order: needs, error, working, then done (idle).
    var pipRank: Int {
        switch self {
        case .needs: 0
        case .error: 1
        case .working: 2
        case .idle: 3
        }
    }
}

/// Where pips sit: an arc under the orb, in y-down view space.
public enum PipArc {
    public static let designStepDegrees = 11.0
    /// Neighbouring pips never sit closer than this along the arc, so small orbs spread them wider.
    public static let minSpacing: CGFloat = 8.8

    public static func stepDegrees(radius: CGFloat) -> Double {
        guard radius > 0 else { return designStepDegrees }
        return max(designStepDegrees, Double(minSpacing / radius) * 180 / .pi)
    }
    /// Arc radius as a multiple of the orb's radius (the design's 100 / 78).
    public static let radiusScale: CGFloat = 1.28
    public static let hitTolerance: CGFloat = 7

    /// `around` turns the whole arc around the orb (view degrees, y-down; 90 = hanging straight down).
    public static func position(slot: Int, slots: Int, centre: CGPoint, radius: CGFloat, around: Double = 90) -> CGPoint {
        let degrees = around - (Double(slot) - Double(slots - 1) / 2) * stepDegrees(radius: radius)
        let a = degrees * .pi / 180
        return CGPoint(x: centre.x + CGFloat(cos(a)) * radius, y: centre.y + CGFloat(sin(a)) * radius)
    }

    /// Where to turn the arc so every pip is on screen: the angle nearest to straight down (checked every 5°)
    /// that keeps each slot at least 6pt inside `visible`, else the one with the most slots inside.
    /// `centre` and `visible` are in screen space (y-up); the result is view degrees like `position`'s `around`.
    public static func around(centre: CGPoint, radius: CGFloat, slots: Int, visible: CGRect) -> Double {
        guard slots > 0 else { return 90 }
        let inner = visible.insetBy(dx: 16, dy: 16)
        func inside(_ a: Double) -> Int {
            (0..<slots).filter { i in
                let p = position(slot: i, slots: slots, centre: .zero, radius: radius, around: a)
                return inner.contains(CGPoint(x: centre.x + p.x, y: centre.y - p.y))   // view y-down → screen y-up
            }.count
        }
        func offDown(_ a: Double) -> Double { let d = abs((a - 90).truncatingRemainder(dividingBy: 360)); return min(d, 360 - d) }
        let candidates = stride(from: 90.0, to: 450, by: 5).map { $0.truncatingRemainder(dividingBy: 360) }
        let scored = candidates.map { (angle: $0, inside: inside($0)) }
        guard let best = scored.max(by: { a, b in
            a.inside != b.inside ? a.inside < b.inside : offDown(a.angle) > offDown(b.angle)
        }) else { return 90 }
        guard best.angle != 90 else { return 90 }
        // Turned: go a little further than the bare minimum, so the pips sit comfortably on screen.
        let away = (best.angle - 90 + 540).truncatingRemainder(dividingBy: 360) - 180
        let further = (best.angle + (away > 0 ? 12 : -12) + 360).truncatingRemainder(dividingBy: 360)
        return inside(further) >= best.inside ? further : best.angle
    }

    /// The session whose visible pip is nearest `point`, within half the pip spacing (at most 7pt), if any.
    public static func hit(_ point: CGPoint, frame: PipsFrame, centre: CGPoint, radius: CGFloat, around: Double = 90) -> String? {
        guard frame.visible, !frame.merged else { return nil }
        let spacing = radius * CGFloat(stepDegrees(radius: radius) * .pi / 180)
        let tolerance = min(hitTolerance, spacing / 2)
        var best: (id: String, distance: CGFloat)?
        for pip in frame.pips {
            guard let slot = pip.slot else { continue }
            let p = position(slot: slot, slots: frame.slots, centre: centre, radius: radius, around: around)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (pip.id, d) }
        }
        return best?.id
    }
}
