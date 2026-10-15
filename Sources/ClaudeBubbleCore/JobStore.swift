import Foundation

/// What Claude Code's background-session manager says about a session: its title and a
/// one-line summary of what it's doing. These are internal files, so every field is optional.
public struct JobInfo: Equatable, Sendable {
    public let name: String?
    public let detail: String?
    public let state: String?
    public let updatedAt: Date?
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
    }

    /// Jobs live in `<dir>/<first 8 chars of the session id>/state.json`; the full id must match.
    public static func load(sessionId: String, from dir: URL) -> JobInfo? {
        guard sessionId.count >= 8 else { return nil }
        let url = dir.appendingPathComponent(String(sessionId.prefix(8))).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.sessionId == sessionId else { return nil }
        return JobInfo(name: record.name, detail: record.detail, state: record.state,
                       updatedAt: record.updatedAt.flatMap(parseDate))
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
