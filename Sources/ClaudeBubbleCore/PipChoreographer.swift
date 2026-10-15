import CoreGraphics
import Foundation

public struct PipInput: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    public init(id: String, state: BubbleState) {
        self.id = id
        self.state = state
    }
}

public enum PipEvent: Equatable, Sendable {
    /// One session finished while others are still active.
    case ringPop
    /// A new session's pip is being drawn out of the orb.
    case spawned(String)
    /// Every session has finished (the pips merge): the orb's full celebration.
    case allDone
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
        if records.keys.contains(where: { !ids.contains($0) }) {
            records = records.filter { ids.contains($0.key) }
            mergeCheckAt = now + Self.mergeDelay
        }
        for input in inputs {
            guard var rec = records[input.id] else {
                records[input.id] = Record(id: input.id, order: nextOrder, state: input.state, rankState: input.state,
                                           spawnedAt: now)
                nextOrder += 1
                events.append(.spawned(input.id))
                if input.state != .idle { merged = false; finishPending = false }
                mergeCheckAt = now + Self.mergeDelay
                continue
            }
            guard rec.state != input.state else { continue }
            rec.state = input.state
            if input.state == .idle {
                rec.flareStart = now
                rec.retireAt = now + Self.retireDelay
                mergeCheckAt = now + Self.mergeDelay
                finishPending = true
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
            }
            records[input.id] = rec
        }
        return events
    }

    public func frame(now: Double) -> PipsFrame {
        advance(now)
        let sorted = records.values.sorted {
            ($0.rankState.pipRank, $0.order) < ($1.rankState.pipRank, $1.order)
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
                            hopping: hop, shake: shake)
        }
        return PipsFrame(pips: pips, slots: over ? Self.maxSlots : n, overflow: over ? n - (Self.maxSlots - 1) : 0,
                         merged: merged, visible: n >= 2)
    }

    private func advance(_ now: Double) {
        for (id, rec) in records {
            if let at = rec.retireAt, now >= at {
                records[id]?.rankState = .idle
                records[id]?.retireAt = nil
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
    public static let stepDegrees = 11.0
    /// Arc radius as a multiple of the orb's radius (the design's 100 / 78).
    public static let radiusScale: CGFloat = 1.28
    public static let hitTolerance: CGFloat = 7

    public static func position(slot: Int, slots: Int, centre: CGPoint, radius: CGFloat) -> CGPoint {
        let degrees = 90 - (Double(slot) - Double(slots - 1) / 2) * stepDegrees
        let a = degrees * .pi / 180
        return CGPoint(x: centre.x + CGFloat(cos(a)) * radius, y: centre.y + CGFloat(sin(a)) * radius)
    }

    /// The session whose visible pip is nearest `point`, within half the pip spacing (at most 7pt), if any.
    public static func hit(_ point: CGPoint, frame: PipsFrame, centre: CGPoint, radius: CGFloat) -> String? {
        guard frame.visible, !frame.merged else { return nil }
        let spacing = radius * CGFloat(stepDegrees * .pi / 180)
        let tolerance = min(hitTolerance, spacing / 2)
        var best: (id: String, distance: CGFloat)?
        for pip in frame.pips {
            guard let slot = pip.slot else { continue }
            let p = position(slot: slot, slots: frame.slots, centre: centre, radius: radius)
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= tolerance, d < (best?.distance ?? .infinity) { best = (pip.id, d) }
        }
        return best?.id
    }
}
