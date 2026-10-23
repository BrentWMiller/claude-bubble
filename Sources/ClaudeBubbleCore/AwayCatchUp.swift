import CoreGraphics
import Foundation

/// Where a session stood when you left: its state, its last update, and how far its transcript went.
public struct SessionMark: Equatable, Sendable {
    public let state: BubbleState
    public let updatedAt: Date
    public let transcriptOffset: UInt64

    public init(state: BubbleState, updatedAt: Date, transcriptOffset: UInt64) {
        self.state = state
        self.updatedAt = updatedAt
        self.transcriptOffset = transcriptOffset
    }
}

/// A changed session's line in the catch-up: being written by Claude (the plain line meanwhile, if there is one),
/// plain (the first sentence of Claude's last message), or written by Claude at a time.
public enum AwayLine: Equatable, Sendable {
    case pending(plain: String?)
    case plain(String)
    case written(String, at: Date)

    public var text: String? {
        switch self {
        case let .pending(plain): plain
        case let .plain(text): text
        case let .written(text, _): text
        }
    }
}

public struct AwayItem: Equatable, Sendable {
    public let sessionID: String
    public var line: AwayLine

    public init(sessionID: String, line: AwayLine) {
        self.sessionID = sessionID
        self.line = line
    }
}

/// The catch-up's groups, most pressing first.
public enum AwayGroup: CaseIterable, Sendable {
    case needsYou, finished, failed, stillWorking

    public var title: String {
        switch self {
        case .needsYou: "NEEDS YOU"
        case .finished: "FINISHED"
        case .failed: "FAILED"
        case .stillWorking: "STILL WORKING"
        }
    }

    public static func of(_ state: BubbleState) -> AwayGroup {
        switch state {
        case .needs: .needsYou
        case .idle: .finished
        case .error: .failed
        case .working: .stillWorking
        }
    }
}

/// What changed while you were away (not the quiet-mode toast replay, `CatchUp`): the sessions with news, each
/// with a line, until you've seen it.
public struct AwayCatchUp: Equatable, Sendable {
    public let leftAt: Date
    public var items: [AwayItem]
    public var seen: Bool

    public init(leftAt: Date, items: [AwayItem], seen: Bool) {
        self.leftAt = leftAt
        self.items = items
        self.seen = seen
    }

    /// Where each session stands now; `offsets` are their transcripts' sizes, by session id.
    public static func marks(_ sessions: [Session], offsets: [String: UInt64]) -> [String: SessionMark] {
        Dictionary(sessions.map { ($0.id, SessionMark(state: $0.state, updatedAt: $0.updatedAt, transcriptOffset: offsets[$0.id] ?? 0)) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// The sessions with news since `marks`: a new state, an update after you left, or new altogether. Sessions that
    /// ended aren't in `sessions`, so they drop out.
    public static func changed(_ sessions: [Session], since marks: [String: SessionMark], leftAt: Date) -> [Session] {
        sessions.filter { s in
            guard let mark = marks[s.id] else { return true }
            return mark.state != s.state || s.updatedAt > leftAt
        }
    }

    /// An unseen catch-up and a newer one together: the first leave, the newer line for a session in both.
    public func merging(_ newer: AwayCatchUp) -> AwayCatchUp {
        var items = self.items
        for item in newer.items {
            if let i = items.firstIndex(where: { $0.sessionID == item.sessionID }) { items[i] = item } else { items.append(item) }
        }
        return AwayCatchUp(leftAt: min(leftAt, newer.leftAt), items: items, seen: seen && newer.seen)
    }

    /// The items by their session's state now (so approving one elsewhere moves it), empty groups and ended
    /// sessions left out.
    public func grouped(current: [String: Session]) -> [(AwayGroup, [AwayItem])] {
        AwayGroup.allCases.compactMap { group in
            let mine = items.filter { current[$0.sessionID].map { AwayGroup.of($0.state) == group } ?? false }
            return mine.isEmpty ? nil : (group, mine)
        }
    }
}

/// The catch-up's sizes in the session list (the island works out its height rather than measuring it).
public enum AwayLayout {
    public static let bannerHeight: CGFloat = 46
    public static let maxHeight: CGFloat = 460

    /// The catch-up view's height: header, group headings, items, needs-you items' approval card (by session id) or
    /// reply buttons, and the footer; at most `maxHeight` (it scrolls beyond), but never less than `atLeast`, the list
    /// it replaced (a shorter card would slip out from under the pointer that opened it, and close).
    public static func height(groups: [(AwayGroup, [AwayItem])], approvalHeights: [String: CGFloat], footer: Bool,
                              atLeast: CGFloat = 0) -> CGFloat {
        var h: CGFloat = 52
        for (group, items) in groups {
            h += 30 + 66 * CGFloat(items.count)
            if group == .needsYou {
                for item in items { h += approvalHeights[item.sessionID].map { $0 + 12 } ?? 48 }
            }
        }
        if footer { h += 44 }
        return max(min(h, maxHeight), atLeast)
    }
}
