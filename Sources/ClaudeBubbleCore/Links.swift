import Foundation

/// A link a session is tied to: a GitHub issue, a pull request, or an artifact.
public struct SessionLink: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable { case issue, pr, artifact }
    public let kind: Kind
    /// What the chip says ("#7211", or an artifact's title).
    public let label: String
    public let url: URL

    public init(kind: Kind, label: String, url: URL) {
        self.kind = kind
        self.label = label
        self.url = url
    }
}

/// Finds the GitHub issues a session is about: from its branch name, and from what's said in the conversation.
public enum LinkFinder {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // "team/issue-7211", "fix/7211", "GH-88", "issue_42-login", then "7211-add-roles", "feat/7211-team-form".
    private static let keyed = regex(#"(?:^|[/_-])(?:issues?|gh|bug|fix|ticket)[-_/]?(\d{2,})(?=$|[-_/])"#)
    private static let leading = regex(#"(?:^|/)(\d{2,})(?=$|[-_])"#)

    public static func issue(fromBranch branch: String) -> Int? {
        for re in [keyed, leading] {
            let range = NSRange(branch.startIndex..., in: branch)
            if let m = re.firstMatch(in: branch, range: range), let r = Range(m.range(at: 1), in: branch) {
                return Int(branch[r])
            }
        }
        return nil
    }

    private static let remote = regex(#"github\.com[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$"#)

    /// "owner/repo" for a GitHub remote URL (ssh or https).
    public static func repo(fromRemote url: String) -> String? {
        let s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = remote.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let owner = Range(m.range(at: 1), in: s), let name = Range(m.range(at: 2), in: s) else { return nil }
        return "\(s[owner])/\(s[name])"
    }

    private static let issueURL = regex(#"github\.com/([\w.-]+/[\w.-]+)/issues/(\d+)"#)
    private static let mention = regex(#"\b(?:issues?|fix(?:es|ed)?|close[sd]?|resolve[sd]?)\s*#(\d+)\b"#)

    /// Issues in conversation text, each once, in the order they first appear: issue URLs (any repo), and
    /// "issue #n" / "fixes #n" / "closes #n" mentions (needing `repo`). Pull requests and bare "#n" don't count.
    public static func issues(inText text: String, repo: String?) -> [(repo: String, number: Int)] {
        var found: [(at: Int, repo: String, number: Int)] = []
        let range = NSRange(text.startIndex..., in: text)
        for m in issueURL.matches(in: text, range: range) {
            if let r = Range(m.range(at: 1), in: text), let n = Range(m.range(at: 2), in: text), let num = Int(text[n]) {
                found.append((m.range.location, String(text[r]), num))
            }
        }
        if let repo {
            for m in mention.matches(in: text, range: range) {
                if let n = Range(m.range(at: 1), in: text), let num = Int(text[n]) { found.append((m.range.location, repo, num)) }
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.at < $1.at }.compactMap { f in
            seen.insert("\(f.repo)#\(f.number)").inserted ? (f.repo, f.number) : nil
        }
    }

    public static func issueLink(repo: String, number: Int) -> SessionLink {
        SessionLink(kind: .issue, label: "#\(number)", url: URL(string: "https://github.com/\(repo)/issues/\(number)")!)
    }
}

/// The chips a session shows: its branch's issue, the latest issue mentioned in the conversation, its pull requests,
/// then artifacts. At most four.
public enum SessionLinks {
    public static let maxShown = 4

    /// `mentioned` is oldest first (the latest is the most relevant).
    public static func merge(job: [SessionLink], branchIssue: Int?, mentioned: [Int], repo: String?) -> [SessionLink] {
        var issues: [SessionLink] = []
        if let repo {
            if let n = branchIssue { issues.append(LinkFinder.issueLink(repo: repo, number: n)) }
            if let latest = mentioned.last(where: { $0 != branchIssue }) { issues.append(LinkFinder.issueLink(repo: repo, number: latest)) }
        }
        let prs = job.filter { $0.kind == .pr }, artifacts = job.filter { $0.kind == .artifact }
        return Array((issues + prs + artifacts).prefix(maxShown))
    }
}
