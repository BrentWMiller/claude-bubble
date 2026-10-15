import CoreGraphics
import Foundation

public enum PipLayout {
    public struct Result: Equatable, Sendable {
        public let states: [BubbleState]
        public let overflow: Int
        public init(states: [BubbleState], overflow: Int) {
            self.states = states
            self.overflow = overflow
        }
    }

    /// One pip per session, most urgent first; a single session needs no pips.
    public static func pips(for sessions: [Session], max: Int = 6) -> Result {
        guard sessions.count >= 2 else { return Result(states: [], overflow: 0) }
        let states = SessionStore.sorted(sessions).map(\.state)
        guard states.count > max else { return Result(states: states, overflow: 0) }
        return Result(states: Array(states.prefix(max - 1)), overflow: states.count - (max - 1))
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
    public static let openDelay: Double = 0.3
    public static let closeDelay: Double = 0.25

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

    public mutating func update(overOrb: Bool, overList: Bool, hasContent: Bool, now: Double) -> Bool {
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
            if !isOpen, now - since >= Self.openDelay { isOpen = true }
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
