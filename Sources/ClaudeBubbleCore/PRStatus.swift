import Foundation

/// A pull request's live status (from `gh pr view --json state,isDraft,reviewDecision,statusCheckRollup`).
public struct PRStatus: Equatable, Hashable, Sendable {
    public enum State: Sendable { case open, draft, merged, closed }
    public enum Checks: Sendable { case passing, failing, pending, none }
    public enum Review: Sendable { case approved, changesRequested, none }

    public let state: State
    public let checks: Checks
    public let review: Review

    public init(state: State, checks: Checks, review: Review) {
        self.state = state
        self.checks = checks
        self.review = review
    }

    public static func parse(_ data: Data) -> PRStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["state"] as? String else { return nil }
        let state: State = switch raw {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: (root["isDraft"] as? Bool) == true ? .draft : .open
        }
        let review: Review = switch root["reviewDecision"] as? String {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        default: .none
        }
        return PRStatus(state: state, checks: checks(root["statusCheckRollup"] as? [[String: Any]] ?? []), review: review)
    }

    /// Any failure fails; otherwise anything unfinished is pending; otherwise passing (none when there are no checks).
    static func checks(_ rollup: [[String: Any]]) -> Checks {
        guard !rollup.isEmpty else { return .none }
        var pending = false
        for c in rollup {
            if c["__typename"] as? String == "StatusContext" {
                switch c["state"] as? String {
                case "FAILURE", "ERROR": return .failing
                case "SUCCESS": break
                default: pending = true
                }
            } else {
                if c["status"] as? String != "COMPLETED" { pending = true; continue }
                switch c["conclusion"] as? String {
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": return .failing
                default: break
                }
            }
        }
        return pending ? .pending : .passing
    }

    /// Puts each known status on its pull request or issue chip (an issue's is just open or closed). A session whose pull requests are all merged (or closed) is
    /// no longer "Ready for review": it reads "Merged #n" instead.
    public static func apply(_ statuses: [URL: PRStatus], to sessions: [Session]) -> [Session] {
        sessions.map { s in
            guard s.links.contains(where: { $0.kind != .artifact }) else { return s }
            let links = s.links.map { link -> SessionLink in
                var l = link
                if l.kind != .artifact { l.status = statuses[l.url] }
                return l
            }
            var out = s
            out.links = links
            let prs = links.filter { $0.kind == .pr }
            guard !prs.isEmpty else { return out }
            let done = prs.allSatisfy { $0.status?.state == .merged || $0.status?.state == .closed }
            if s.reviewReady, done {
                let merged = prs.last { $0.status?.state == .merged }
                out = s.replacing(reviewReady: false, detail: merged.map { "Merged \($0.label)" } ?? "PR closed")
            }
            out.links = links
            return out
        }
    }
}

/// How often to re-check a pull request (or issue). In the background: every 2 minutes while its checks run, every 10 at rest,
/// never once merged or closed, and not at all for sessions quiet for two hours. While someone's looking (the hover list
/// or island panel is open): anything older than 30 seconds.
public enum PRPolling {
    public static let quietAfter: TimeInterval = 2 * 3600

    /// Seconds between checks, or nil to leave it alone. `fetched`: it has been asked about before.
    public static func interval(status: PRStatus?, fetched: Bool, looking: Bool, sessionIdle: TimeInterval) -> TimeInterval? {
        if let s = status, s.state == .merged || s.state == .closed { return nil }
        if !fetched { return 0 }
        if looking { return 30 }
        guard sessionIdle < quietAfter else { return nil }
        return status?.checks == .pending ? 120 : 600
    }
}
