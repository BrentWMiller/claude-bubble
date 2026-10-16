import CoreGraphics
import Foundation

/// How a session's status line is coloured in the list, following the agents view's groups.
public enum StatusTone: Equatable, Sendable {
    /// Needs input or Ready for review (orange).
    case attention
    case error
    case working
    /// Finished (green).
    case completed
    /// Went quiet without finishing (grey).
    case idle
}

extension Session {
    public var tone: StatusTone {
        if reviewReady { return .attention }
        switch state {
        case .needs: return .attention
        case .error: return .error
        case .working: return .working
        case .idle: return detail == "Idle" ? .idle : .completed
        }
    }
}

/// The hover card's pop-in and pop-out, in the toasts' style: it unfolds from the orb's side, eases out of the orb
/// with a slight overshoot, and its rows cascade in; leaving, it slips back toward the orb and closes.
public enum CardMotion {
    public struct Pose: Equatable, Sendable {
        public let opacity: Double
        public let scale: Double
        /// Points shifted toward the orb.
        public let offset: Double
        /// 0 (closed) … 1 (fully revealed).
        public let reveal: Double
    }

    public static let showDuration = 0.45
    public static let hideDuration = 0.22

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeIn(_ x: Double) -> Double { x * x * x }
    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158 * 0.6, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    public static func appear(age: Double) -> Pose {
        let p = clamp(age / showDuration)
        return Pose(opacity: easeOut(clamp(p * 1.4)), scale: 0.96 + 0.04 * easeOutBack(p),
                    offset: 8 * (1 - easeOut(p)), reveal: easeOut(clamp(age / 0.4)))
    }

    public static func disappear(age: Double) -> Pose {
        let e = easeIn(clamp(age / hideDuration))
        return Pose(opacity: 1 - e, scale: 1 - 0.03 * e, offset: 6 * e, reveal: 1 - e)
    }

    /// Row `index`'s entrance progress (each row a little after the one before).
    public static func row(_ index: Int, age: Double) -> Double {
        easeOut(clamp((age - 0.08 - Double(index) * 0.04) / 0.3))
    }
}

public enum ElapsedFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let s = Int(Swift.max(0, seconds))
        switch s {
        case ..<600: return String(format: "%d:%02d", s / 60, s % 60)
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }
}

/// Open after resting on the orb, stay open while over orb or list, close shortly after leaving both.
public struct HoverTracker {
    public static let openDelay: Double = 0.6
    /// The docked island sits out of the way at the screen's edge, so reaching it is deliberate: open at once.
    public static let islandOpenDelay: Double = 0
    public static let closeDelay: Double = 0.35

    public private(set) var isOpen = false
    private var insideSince: Double?
    private var outsideSince: Double?
    /// Set by dismiss(); the orb can't reopen the list until the pointer has left it.
    private var suppressed = false

    public init() {}

    /// Close now (e.g. after a row was clicked) without the close delay bringing it back.
    public mutating func dismiss() {
        isOpen = false
        insideSince = nil
        outsideSince = nil
        suppressed = true
    }

    public mutating func update(overOrb: Bool, overList: Bool, hasContent: Bool, now: Double,
                                openDelay: Double = HoverTracker.openDelay) -> Bool {
        guard hasContent else {
            isOpen = false
            insideSince = nil
            outsideSince = nil
            return false
        }
        if suppressed {
            if overOrb { return false }
            suppressed = false
        }
        let inside = overOrb || (isOpen && overList)
        if inside {
            outsideSince = nil
            let since = insideSince ?? now
            insideSince = since
            if !isOpen, now - since >= openDelay { isOpen = true }
        } else {
            insideSince = nil
            if isOpen {
                let since = outsideSince ?? now
                outsideSince = since
                if now - since >= Self.closeDelay {
                    isOpen = false
                    outsideSince = nil
                }
            }
        }
        return isOpen
    }
}

public enum SessionListPlacement {
    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 8

    /// The orb fills the central 60% of the bubble panel.
    public static func orbRect(panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: panelFrame.width * 0.2, dy: panelFrame.height * 0.2)
    }

    /// Below the orb when it fits, otherwise above; centred on the orb and kept inside the screen.
    public static func frame(listSize: CGSize, orbRect: CGRect, visibleFrame: CGRect) -> CGRect {
        let centred = orbRect.midX - listSize.width / 2
        let x = Swift.min(Swift.max(centred, visibleFrame.minX + margin), visibleFrame.maxX - listSize.width - margin)
        let below = orbRect.minY - gap - listSize.height
        let y = below >= visibleFrame.minY + margin ? below : orbRect.maxY + gap
        return CGRect(x: x, y: y, width: listSize.width, height: listSize.height)
    }
}
