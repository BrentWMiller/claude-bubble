import Foundation

/// What a chip's hover card shows: a pull request's title, size, checks and review, or an issue's title, labels,
/// assignees and comments. Parsed from `gh pr view --json …` / `gh issue view --json …`.
public struct LinkPreview: Equatable, Sendable {
    public struct Label: Equatable, Sendable {
        public let name: String
        /// Hex without the "#", as GitHub gives it.
        public let color: String

        public init(name: String, color: String) {
            self.name = name
            self.color = color
        }
    }

    public let title: String
    public var author: String?
    // Pull requests
    public var additions: Int?
    public var deletions: Int?
    public var changedFiles: Int?
    /// Names of the checks that failed, in GitHub's order.
    public var failed: [String] = []
    public var passed = 0
    public var running = 0
    /// "Approved by x, y" / "Changes requested by z".
    public var review: String?
    // Issues
    public var labels: [Label] = []
    public var assignees: [String] = []
    public var comments: Int?
    /// Merged or closed: it won't change, so it's never fetched again.
    public var final = false

    public init(title: String) { self.title = title }

    /// How long a fetched preview is shown without a refresh behind it.
    public static let freshFor: TimeInterval = 60

    /// Whether to fetch again (in the background, showing the cached one meanwhile). `age`: nil when never fetched.
    public static func needsRefresh(final: Bool, age: TimeInterval?) -> Bool {
        guard let age else { return true }
        return !final && age > freshFor
    }

    public static func parsePullRequest(_ data: Data) -> LinkPreview? {
        guard let root = object(data), let title = root["title"] as? String else { return nil }
        var p = LinkPreview(title: title)
        p.author = (root["author"] as? [String: Any])?["login"] as? String
        p.additions = root["additions"] as? Int
        p.deletions = root["deletions"] as? Int
        p.changedFiles = root["changedFiles"] as? Int
        p.final = ["MERGED", "CLOSED"].contains(root["state"] as? String ?? "")
        for c in root["statusCheckRollup"] as? [[String: Any]] ?? [] {
            let name = c["name"] as? String ?? c["context"] as? String ?? "check"
            if c["__typename"] as? String == "StatusContext" {
                switch c["state"] as? String {
                case "FAILURE", "ERROR": p.failed.append(name)
                case "SUCCESS": p.passed += 1
                default: p.running += 1
                }
            } else if c["status"] as? String != "COMPLETED" {
                p.running += 1
            } else {
                switch c["conclusion"] as? String {
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": p.failed.append(name)
                default: p.passed += 1
                }
            }
        }
        let reviews = root["latestReviews"] as? [[String: Any]] ?? []
        func by(_ state: String) -> String {
            reviews.filter { $0["state"] as? String == state }
                .compactMap { ($0["author"] as? [String: Any])?["login"] as? String }.joined(separator: ", ")
        }
        switch root["reviewDecision"] as? String {
        case "APPROVED": let who = by("APPROVED"); p.review = who.isEmpty ? "Approved" : "Approved by \(who)"
        case "CHANGES_REQUESTED": let who = by("CHANGES_REQUESTED"); p.review = who.isEmpty ? "Changes requested" : "Changes requested by \(who)"
        case "REVIEW_REQUIRED": p.review = "Review required"
        default: break
        }
        return p
    }

    public static func parseIssue(_ data: Data) -> LinkPreview? {
        guard let root = object(data), let title = root["title"] as? String else { return nil }
        var p = LinkPreview(title: title)
        p.author = (root["author"] as? [String: Any])?["login"] as? String
        p.labels = (root["labels"] as? [[String: Any]] ?? []).compactMap { l in
            (l["name"] as? String).map { Label(name: $0, color: l["color"] as? String ?? "888888") }
        }
        p.assignees = (root["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
        p.comments = (root["comments"] as? [Any])?.count ?? root["comments"] as? Int
        p.final = root["state"] as? String == "CLOSED"
        return p
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
