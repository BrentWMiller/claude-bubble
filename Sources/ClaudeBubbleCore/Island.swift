import CoreGraphics
import Foundation

/// How Claude Bubble presents itself: the floating orb, or a pill docked to a screen edge.
public enum BubbleStyle: String, Codable, CaseIterable, Sendable { case orb, island }

public enum IslandDock: String, Codable, CaseIterable, Sendable {
    case top, bottom, left, right
    public var isSide: Bool { self == .left || self == .right }
}

/// Resting island: the orb with the current activity and pips, or just the orb and pips.
public enum IslandRest: String, Codable, CaseIterable, Sendable { case live, compact }

/// The glow inside the pill: a rolling dot-wave with an inner glow, or a plain black pill.
public enum IslandGlow: String, Codable, CaseIterable, Sendable { case waves, none }

/// What the island is showing (design: Top Island). Highest priority first: hover, needs, error, done, rest.
public enum IslandMode: Equatable, Sendable {
    case rest
    case needs(String)
    case error(String)
    case done
    case hover

    public static let errorShown: TimeInterval = 3.5
    public static let doneShown: TimeInterval = 4.5

    /// `doneAt` is the all-done moment (the pips' merge), if any.
    public static func choose(sessions: [Session], now: Date, hovering: Bool, doneAt: Date?) -> IslandMode {
        if hovering { return .hover }
        let recent = sessions.sorted { $0.stateSince > $1.stateSince }
        if let s = recent.first(where: { $0.state == .needs }) { return .needs(s.id) }
        if let s = recent.first(where: { $0.state == .error && now.timeIntervalSince($0.stateSince) < errorShown }) {
            return .error(s.id)
        }
        if let d = doneAt, now.timeIntervalSince(d) < doneShown { return .done }
        return .rest
    }
}

public enum IslandLayout {
    /// The island's window: large enough for the biggest pill, so it never moves or resizes.
    public static let windowSize = CGSize(width: 380, height: 440)
    public static let orbSize: CGFloat = 28
    public static let pipSize: CGFloat = 5
    public static let maxPips = 5
    /// A session row plus the list's 2pt spacing.
    public static let rowHeight: CGFloat = 51
    /// The most rows the hover panel shows (the rest fold into "+N more"), so it always fits the window.
    public static let maxRows = 6
    public static let moreHeight: CGFloat = 20
    /// Breathing room at the panel's open end (under the footer, or above the first row on a bottom dock).
    public static let openPadding: CGFloat = 10

    public static func shownRows(_ count: Int) -> Int { min(count, maxRows) }
    public static let cornerRadius: CGFloat = 22

    /// `footer`: the hover panel's Today/usage line is showing.
    public static func size(mode: IslandMode, dock: IslandDock, rest: IslandRest, pips: Int, rows: Int,
                            footer: Bool = true) -> CGSize {
        switch mode {
        case .hover:
            let shown = CGFloat(max(shownRows(rows), 1))
            let more = rows > maxRows ? moreHeight : 0
            return CGSize(width: 350, height: 46 + rowHeight * shown + more + (footer ? 34 : 6) + openPadding)
        case .needs, .error: return CGSize(width: 360, height: 98)
        case .done: return CGSize(width: 300, height: 44)
        case .rest:
            if dock.isSide {
                let n = CGFloat(min(pips, maxPips))
                let column = n > 0 ? 10 + n * pipSize + (n - 1) * 4 : 0
                return CGSize(width: 44, height: 8 + orbSize + column + 12)
            }
            return CGSize(width: rest == .compact ? 130 : 290, height: 44)
        }
    }

    /// Flush with the docked edge of the visible frame (so a top island sits just under the menu bar).
    public static func windowFrame(dock: IslandDock, visible v: CGRect) -> CGRect {
        let w = windowSize
        switch dock {
        case .top: return CGRect(x: v.midX - w.width / 2, y: v.maxY - w.height, width: w.width, height: w.height)
        case .bottom: return CGRect(x: v.midX - w.width / 2, y: v.minY, width: w.width, height: w.height)
        case .left: return CGRect(x: v.minX, y: v.midY - w.height / 2, width: w.width, height: w.height)
        case .right: return CGRect(x: v.maxX - w.width, y: v.midY - w.height / 2, width: w.width, height: w.height)
        }
    }

    /// The pill inside the window: on the docked edge, centred along it (screen space).
    public static func pillRect(size: CGSize, dock: IslandDock, window w: CGRect) -> CGRect {
        switch dock {
        case .top: return CGRect(x: w.midX - size.width / 2, y: w.maxY - size.height, width: size.width, height: size.height)
        case .bottom: return CGRect(x: w.midX - size.width / 2, y: w.minY, width: size.width, height: size.height)
        case .left: return CGRect(x: w.minX, y: w.midY - size.height / 2, width: size.width, height: size.height)
        case .right: return CGRect(x: w.maxX - size.width, y: w.midY - size.height / 2, width: size.width, height: size.height)
        }
    }
}

extension ToastLayout {
    /// Toasts hang off the island's open side: under a top (or side) island, above a bottom one.
    public static func placeIsland(pill: CGRect, dock: IslandDock, size: CGSize, visible: CGRect) -> Placement {
        var frame = CGRect(x: pill.midX - size.width / 2, y: pill.minY - 12 - size.height, width: size.width, height: size.height)
        var flipped = false, align = Align.center
        var pull: SIMD2<Float> = [0, -1]
        switch dock {
        case .top: break
        case .bottom:
            frame.origin.y = pill.maxY + 12
            flipped = true
            pull = [0, 1]
        case .left:
            frame.origin.x = pill.minX
            align = .leading
        case .right:
            frame.origin.x = pill.maxX - size.width
            align = .trailing
        }
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        return Placement(frame: frame, flipped: flipped, align: align, pull: pull)
    }
}
