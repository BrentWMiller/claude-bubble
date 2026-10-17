import Foundation

/// What Claude Code's background-session manager says about a session: its title and a
/// one-line summary of what it's doing. These are internal files, so every field is optional.
public struct JobInfo: Equatable, Sendable {
    public let name: String?
    public let detail: String?
    public let state: String?
    public let updatedAt: Date?
    /// The session's current context size.
    public let tokens: Int?
    /// It opened a pull request (a `children` link of kind "pr"): the agents view's "Ready for review".
    public var hasPullRequest = false
    /// Its pull requests and artifacts (the agents view's `children`), as chips.
    public var links: [SessionLink] = []
}

public enum JobStore {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/jobs", isDirectory: true)
    }

    private struct Record: Decodable {
        let sessionId: String?
        let name: String?
        let detail: String?
        let state: String?
        let updatedAt: String?
        let tokens: Int?
        let children: [Child]?
    }

    private struct Child: Decodable {
        let kind: String?
        let id: String?
        let href: String?
        let title: String?

        var link: SessionLink? {
            guard let href, let url = URL(string: href) else { return nil }
            switch kind {
            case "pr": return SessionLink(kind: .pr, label: "#\(id ?? url.lastPathComponent)", url: url)
            case "frame", "artifact": return SessionLink(kind: .artifact, label: title ?? id ?? "Artifact", url: url)
            default: return nil
            }
        }
    }

    /// Jobs live in `<dir>/<first 8 chars of the session id>/state.json`; the full id must match.
    public static func load(sessionId: String, from dir: URL, cache: FileCache<JobInfo>? = nil) -> JobInfo? {
        guard sessionId.count >= 8 else { return nil }
        let url = dir.appendingPathComponent(String(sessionId.prefix(8))).appendingPathComponent("state.json")
        let decode = { (data: Data) in decodeJob(data, sessionId: sessionId) }
        return cache.map { $0.value(at: url, decode: decode) } ?? (try? Data(contentsOf: url)).flatMap(decode)
    }

    private static func decodeJob(_ data: Data, sessionId: String) -> JobInfo? {
        guard let record = try? JSONDecoder().decode(Record.self, from: data), record.sessionId == sessionId else { return nil }
        return JobInfo(name: record.name, detail: record.detail, state: record.state,
                       updatedAt: record.updatedAt.flatMap(parseDate), tokens: record.tokens,
                       hasPullRequest: record.children?.contains { $0.kind == "pr" } ?? false,
                       links: record.children?.compactMap(\.link) ?? [])
    }

    // ISO8601DateFormatter is thread-safe; making one is the costly part.
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }
}
