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
    /// Quiet mode (a Focus, a screen share, or the toggle): a single dot.
    case quiet
    /// Closed to a circle around the orb, as the floating orb flies in or out (switching style). Never chosen.
    case tucked

    public static let errorShown: TimeInterval = 3.5
    public static let doneShown: TimeInterval = 4.5

    /// `doneAt` is the all-done moment (the pips' merge), if any.
    public static func choose(sessions: [Session], now: Date, hovering: Bool, doneAt: Date?, quiet: Bool = false) -> IslandMode {
        if hovering { return .hover }
        if quiet { return .quiet }
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
    /// The island's window: large enough for the biggest pill (the open panel at its tallest: every row with link
    /// chips, "+N more" and the footer) plus room for its drop shadow to fade out, so it never moves or resizes.
    public static var windowSize: CGSize {
        let tallest = size(mode: .hover, dock: .top, rest: .live, pips: 0, rows: maxRows + 1, linked: maxRows,
                           approval: maxApprovalHeight)
        return CGSize(width: 440, height: (tallest.height + 50).rounded(.up))
    }
    public static let orbSize: CGFloat = 28
    public static let pipSize: CGFloat = 5
    public static let maxPips = 5
    /// A session row plus the list's 2pt spacing.
    public static let rowHeight: CGFloat = 51
    /// The most rows the hover panel shows (the rest fold into "+N more"), so it always fits the window.
    public static let maxRows = 6
    public static let moreHeight: CGFloat = 20
    /// A session row's link chips (issue, pull request, artifact) add this much.
    public static let linkRowHeight: CGFloat = 28
    /// The tallest approval card (see ApprovalCardLayout), which the window leaves room for.
    public static let maxApprovalHeight: CGFloat = 240
    /// A needs-you card with an approval card: the bar, the headline, the card and padding.
    public static let approvalChrome: CGFloat = 44

    /// How many of the hover panel's shown rows carry link chips.
    public static func linkedRows(_ sessions: [Session]) -> Int {
        SessionStore.sorted(sessions).prefix(maxRows).filter { !$0.links.isEmpty }.count
    }

    /// Breathing room at the panel's open end (under the footer, or above the first row on a bottom dock).
    public static let openPadding: CGFloat = 10

    public static func shownRows(_ count: Int) -> Int { min(count, maxRows) }
    public static let cornerRadius: CGFloat = 22
    /// Quiet mode's dot.
    public static let quietDot: CGFloat = 16
    /// The bar's padding: tight against the docked edge, roomier on the open side.
    public static let dockedInset: CGFloat = 4
    public static let openInset: CGFloat = 8
    /// The bar: the orb with its padding (40pt).
    public static var barHeight: CGFloat { dockedInset + orbSize + openInset }

    /// `footer`: the hover panel's Today/usage line is showing. `approval`: the height of the approval card showing
    /// (on the needs-you card, or under one row of the hover panel), 0 for none.
    public static func size(mode: IslandMode, dock: IslandDock, rest: IslandRest, pips: Int, rows: Int,
                            footer: Bool = true, linked: Int = 0, approval: CGFloat = 0) -> CGSize {
        switch mode {
        case .quiet: return CGSize(width: quietDot, height: quietDot)
        case .tucked: return dock.isSide ? CGSize(width: 44, height: 44) : CGSize(width: 48, height: barHeight)
        case .hover:
            let shown = CGFloat(max(shownRows(rows), 1))
            let more = rows > maxRows ? moreHeight : 0
            return CGSize(width: 350, height: barHeight + 2 + rowHeight * shown + linkRowHeight * CGFloat(linked) + more
                                            + (approval > 0 ? approval + 8 : 0) + (footer ? 34 : 6) + openPadding)
        case .needs: return CGSize(width: 360, height: barHeight + (approval > 0 ? approvalChrome + approval : 54))
        case .error: return CGSize(width: 360, height: barHeight + 54)
        case .done: return CGSize(width: 300, height: barHeight)
        case .rest:
            if dock.isSide {
                let n = CGFloat(min(pips, maxPips))
                let column = n > 0 ? 10 + n * pipSize + (n - 1) * 4 : 0
                return CGSize(width: 44, height: 8 + orbSize + column + 12)
            }
            return CGSize(width: rest == .compact ? 130 : 290, height: barHeight)
        }
    }

    /// Flush with the docked edge of the visible frame (so a top island sits just under the menu bar), `along` that
    /// edge (0 = left/bottom end, 1 = right/top end), kept wholly on screen so it stays clear of the corners.
    public static func windowFrame(dock: IslandDock, visible v: CGRect, along: Double = 0.5) -> CGRect {
        let w = windowSize, a = CGFloat(min(max(along, 0), 1))
        let x = min(max(v.minX + a * v.width - w.width / 2, v.minX), v.maxX - w.width)
        let y = min(max(v.minY + a * v.height - w.height / 2, v.minY), v.maxY - w.height)
        switch dock {
        case .top: return CGRect(x: x, y: v.maxY - w.height, width: w.width, height: w.height)
        case .bottom: return CGRect(x: x, y: v.minY, width: w.width, height: w.height)
        case .left: return CGRect(x: v.minX, y: y, width: w.width, height: w.height)
        case .right: return CGRect(x: v.maxX - w.width, y: y, width: w.width, height: w.height)
        }
    }

    /// The top of the area the island can use on a screen: just under that screen's menu bar while it's showing,
    /// else the very top (a full-screen app, or an auto-hidden menu bar). `menuBars` are the menu bar windows on screen.
    public static func top(of screen: CGRect, menuBars: [CGRect]) -> CGFloat {
        // Real overlap, not just a shared edge: a neighbouring display's bar starts where this screen ends.
        let bar = menuBars.first {
            $0.minX < screen.maxX - 1 && $0.maxX > screen.minX + 1 && $0.maxY >= screen.maxY - 1 && $0.minY < screen.maxY
        }
        return bar.map { min($0.minY, screen.maxY) } ?? screen.maxY
    }

    /// Window-server window bounds (top-left origin on the main display) as a screen rect.
    public static func cocoaRect(fromWindowBounds b: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: b.minX, y: mainHeight - b.maxY, width: b.width, height: b.height)
    }

    /// Where the orb sits on screen while the island is tucked (in the middle of its circle, against the docked edge).
    public static func tuckedOrbCentre(dock: IslandDock, window: CGRect) -> CGPoint {
        let pill = pillRect(size: size(mode: .tucked, dock: dock, rest: .live, pips: 0, rows: 0), dock: dock, window: window)
        let inset = dockedInset + orbSize / 2
        switch dock {
        case .top: return CGPoint(x: pill.midX, y: pill.maxY - inset)
        case .bottom: return CGPoint(x: pill.midX, y: pill.minY + inset)
        case .left, .right: return CGPoint(x: pill.midX, y: pill.midY)
        }
    }

    /// Dragging: the edge nearest `point`, and how far along it the point is (0…1).
    public static func nearest(_ p: CGPoint, visible v: CGRect) -> (dock: IslandDock, along: Double) {
        let candidates: [(IslandDock, CGFloat)] = [(.top, v.maxY - p.y), (.bottom, p.y - v.minY),
                                                   (.left, p.x - v.minX), (.right, v.maxX - p.x)]
        let dock = candidates.min { $0.1 < $1.1 }!.0
        let along = dock.isSide ? (p.y - v.minY) / v.height : (p.x - v.minX) / v.width
        return (dock, Double(min(max(along, 0), 1)))
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
