import CoreGraphics
import Foundation

/// What a toast announces (design: Pip Sounds toasts).
public enum ToastKind: String, CaseIterable, Sendable {
    case started, needs, error, finished, review, resumed, allDone
    /// Usage thresholds (25% and 10% left) and the window resetting; their text comes with the toast.
    case usageLow, usageCritical, usageRefreshed
    /// Quiet mode's "While you were away" summary; its text comes with the toast.
    case catchUp
    /// A new version of the app is out; its text comes with the toast.
    case update

    public var text: String {
        switch self {
        case .started: "started"
        case .needs: "needs you"
        case .error: "hit an error"
        case .finished: "finished"
        case .review: "ready for review"
        case .resumed: "back to work"
        case .allDone: "complete"
        case .usageLow, .usageCritical, .usageRefreshed: "usage"
        case .catchUp: "updates"
        case .update: "is available"
        }
    }

    /// Seconds on screen (paused while the stack is hovered).
    public var lifetime: Double {
        switch self {
        case .started: 4
        case .needs, .error, .review, .usageCritical, .catchUp, .update: 8
        case .finished, .allDone, .usageLow, .usageRefreshed: 6
        case .resumed: 3.5
        }
    }
}

public struct ToastItem: Equatable, Identifiable, Sendable {
    public let id: Int
    public let kind: ToastKind
    public let name: String
    /// What it says; the kind's own text unless pushed with one (usage toasts carry their numbers).
    public let text: String
    public let born: Double
    var remaining: Double
    public internal(set) var showing: Bool
    var leftAt: Double?
    /// Stack position when it started leaving (so it leaves from where it was).
    var lastK = 0
}

/// Where one toast sits in the stack right now.
public struct ToastPlacement: Equatable, Sendable {
    public let id: Int
    public let kind: ToastKind
    public let name: String
    public let text: String
    public let born: Double
    public let showing: Bool
    public let top: CGFloat
    public let scale: CGFloat
    public let opacity: Double
    public let blur: CGFloat
    public let z: Int
}

/// The toast stack: newest on top, at most five showing, older ones tucked behind (fanned out on hover).
public final class ToastQueue {
    public static let maxShown = 5
    public static let leaveDuration = 0.7

    /// Oldest first.
    public private(set) var items: [ToastItem] = []
    private var nextId = 0
    private var lastTick: Double?

    public init() {}

    public func push(_ kind: ToastKind, name: String, text: String? = nil, now: Double) {
        if lastTick == nil { lastTick = now }
        items.append(ToastItem(id: nextId, kind: kind, name: name, text: text ?? kind.text, born: now,
                               remaining: kind.lifetime, showing: true))
        nextId += 1
        let showing = newestFirst()
        for id in showing.dropFirst(Self.maxShown) { leave(id, now: now) }
    }

    public func tick(now: Double, hovering: Bool) {
        let dt = now - (lastTick ?? now)
        lastTick = now
        if !hovering {
            for i in items.indices where items[i].showing {
                items[i].remaining -= dt
                if items[i].remaining <= 0 { leave(items[i].id, now: now) }
            }
        }
        items.removeAll { $0.leftAt.map { now >= $0 + Self.leaveDuration } ?? false }
    }

    public func clear() {
        items = []
    }

    public var isEmpty: Bool { items.isEmpty }

    public func layout(expanded: Bool) -> [ToastPlacement] {
        let order = newestFirst()
        return items.map { item in
            let k = item.showing ? (order.firstIndex(of: item.id) ?? 0) : item.lastK
            let kf = CGFloat(k)
            let top = expanded ? 6 + 40 * kf : 6 + 7 * kf
            guard item.showing else {
                return ToastPlacement(id: item.id, kind: item.kind, name: item.name, text: item.text, born: item.born, showing: false,
                                      top: top, scale: 0.94, opacity: 0, blur: 0, z: 5 - min(k, 4))
            }
            return ToastPlacement(id: item.id, kind: item.kind, name: item.name, text: item.text, born: item.born, showing: true, top: top,
                                  scale: expanded ? 1 : 1 - 0.055 * kf,
                                  opacity: expanded ? 1 : (k > 2 ? 0 : 1 - 0.3 * Double(k)),
                                  blur: expanded ? 0 : 1.2 * CGFloat(min(k, 3)),
                                  z: 20 - k)
        }
    }

    /// Height of the area the stack occupies (for hover and placement).
    public func stackHeight(expanded: Bool) -> CGFloat {
        let n = items.filter(\.showing).count
        guard n > 0 else { return 0 }
        return expanded ? 6 + 40 * CGFloat(n) : 40 + 7 * CGFloat(min(n - 1, 2))
    }

    private func newestFirst() -> [Int] {
        items.filter(\.showing).sorted { $0.born > $1.born || ($0.born == $1.born && $0.id > $1.id) }.map(\.id)
    }

    private func leave(_ id: Int, now: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].showing else { return }
        items[i].lastK = newestFirst().firstIndex(of: id) ?? 0
        items[i].showing = false
        items[i].leftAt = now
    }

    /// Toasts for a batch of choreographer events. `previous` is the pip frame before them (for "back to work",
    /// which only counts after needs-you or an error). All-done is announced separately, after the merge.
    public static func toasts(for events: [PipEvent], previous: PipsFrame, names: [String: String],
                              reviews: Set<String> = []) -> [(kind: ToastKind, name: String)] {
        func name(_ id: String) -> String { names[id] ?? "session" }
        func wasStuck(_ id: String) -> Bool {
            guard let state = previous.pips.first(where: { $0.id == id })?.state else { return false }
            return state == .needs || state == .error
        }
        return events.compactMap { event in
            switch event {
            case let .spawned(id): (.started, name(id))
            case let .needs(id): (.needs, name(id))
            case let .error(id): (.error, name(id))
            case let .finished(id): (reviews.contains(id) ? .review : .finished, name(id))
            case let .reviewReady(id): (.review, name(id))
            case let .resumed(id): wasStuck(id) ? (.resumed, name(id)) : nil
            default: nil
            }
        }
    }
}

/// The toast's "decode" entrance: characters start as glyphs and resolve left to right.
public enum ToastDecode {
    public static let glyphs: [Character] = Array("▓▒░█<>/\\_=+*#01:;")
    public static let duration = 0.48

    static func rnd(_ n: Double, tick: Int, seed: Int) -> Double {
        let v = sin(n * 12.9898 + Double(tick) * 78.233 + Double(seed) * 3.1) * 43758.5453
        return v - floor(v)
    }

    /// `tick` re-rolls the glyphs (every 45ms); `offset` keeps two strings on one toast from matching.
    public static func text(_ s: String, progress p: Double, seed: Int, tick: Int, offset: Int = 0) -> String {
        guard p < 1 else { return s }
        let chars = Array(s), length = Double(max(chars.count, 1))
        return String(chars.enumerated().map { i, ch in
            if ch == " " { return " " }
            let at = 0.1 + Double(i) / length * 0.55 + rnd(Double(i + offset), tick: tick, seed: seed) * 0.1
            if p >= at { return ch }
            let g = Int(rnd(Double(i * 7 + offset + 1), tick: tick, seed: seed) * Double(glyphs.count))
            return glyphs[min(g, glyphs.count - 1)]
        })
    }
}

/// Where the toast stack goes: centred under the orb (above it if the bottom would cut it off). If a side would
/// cut it off, it moves to the opposite side of the orb instead, its first toast level with the orb's centre and
/// just past the pips. Then it's pulled fully inside the visible frame.
public enum ToastLayout {
    public enum Align: Equatable, Sendable { case leading, center, trailing }

    public struct Placement: Equatable, Sendable {
        public let frame: CGRect
        /// The stack sits above the orb: newest nearest the orb, growing upward.
        public let flipped: Bool
        /// How the toasts sit in the frame: toward the orb when beside it.
        public let align: Align
        /// Which way the orb tugs when a toast appears (toward the stack).
        public let pull: SIMD2<Float>
    }

    /// The first toast's top inset and height in the stack (see `ToastQueue.layout`, `ToastStackView`).
    static let firstToastCentre: CGFloat = 6 + 15

    public static func place(orb: CGRect, size: CGSize, visible: CGRect) -> Placement {
        let radius = orb.width * 0.3
        let reach = radius * 1.49                         // below the pips when they hang under the orb
        let beside = radius * PipArc.radiusScale + 12      // past the pips when they're to the side
        var frame = CGRect(x: orb.midX - size.width / 2, y: orb.midY - reach - size.height,
                           width: size.width, height: size.height)
        var flipped = false, align = Align.center
        var pull: SIMD2<Float> = [0, -1]
        if frame.maxX > visible.maxX || frame.minX < visible.minX {
            // A side would be cut off: go to the other side, level with the orb.
            let left = frame.maxX > visible.maxX
            frame.origin = CGPoint(x: left ? orb.midX - beside - size.width : orb.midX + beside,
                                   y: orb.midY + firstToastCentre - size.height)
            align = left ? .trailing : .leading
            pull = left ? [-1, 0] : [1, 0]
        } else if frame.minY < visible.minY {
            frame.origin.y = orb.midY + reach
            flipped = true
            pull = [0, 1]
        }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return Placement(frame: frame, flipped: flipped, align: align, pull: pull)
    }
}
