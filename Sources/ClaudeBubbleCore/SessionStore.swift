import Foundation

public struct Session: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    public let cwd: String
    public let updatedAt: Date
    public let project: String
    public let detail: String
    public let stateSince: Date
    /// The Claude process that owns this session; nil for files written by an older hook.
    public let pid: Int32?

    public init(id: String, state: BubbleState, cwd: String = "", updatedAt: Date,
                project: String? = nil, detail: String = "", stateSince: Date? = nil, pid: Int32? = nil) {
        self.id = id
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.project = project ?? Session.projectName(for: cwd)
        self.detail = detail
        self.stateSince = stateSince ?? updatedAt
        self.pid = pid
    }

    static func projectName(for cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "session" : name
    }
}

/// Reads the per-session files written by the hook and reduces them to one state.
public enum SessionStore {
    public static let staleAfter: TimeInterval = 15 * 60
    public static let needsStaleAfter: TimeInterval = 60 * 60
    public static let deleteAfter: TimeInterval = 24 * 60 * 60

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-bubble/sessions", isDirectory: true)
    }

    private struct Record: Decodable {
        let state: String
        let cwd: String?
        let updated_at: Double
        let project: String?
        let detail: String?
        let state_since: Double?
        let pid: Int32?
    }

    /// True unless the kernel says the process is gone; a permission error still means it exists.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    public static func load(from dir: URL, now: Date = Date(), isAlive: (Int32) -> Bool = processIsAlive) -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sessions: [Session] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let state = BubbleState(rawValue: record.state) else { continue }
            let updated = Date(timeIntervalSince1970: record.updated_at)
            // pid 0/1 would make kill() target a process group or launchd, so treat it as unknown.
            let pid = record.pid.flatMap { $0 > 1 ? $0 : nil }
            if let pid, !isAlive(pid) {
                try? fm.removeItem(at: url)
                continue
            }
            if pid == nil, now.timeIntervalSince(updated) > deleteAfter {
                try? fm.removeItem(at: url)
                continue
            }
            sessions.append(Session(id: String(name.dropLast(5)), state: state, cwd: record.cwd ?? "", updatedAt: updated,
                                    project: record.project, detail: record.detail ?? "",
                                    stateSince: record.state_since.map(Date.init(timeIntervalSince1970:)), pid: pid))
        }
        return sessions
    }

    /// Sessions worth showing: a live process always counts; without a pid, fall back to staleness.
    public static func live(_ sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.filter { s in
            s.pid != nil || now.timeIntervalSince(s.updatedAt) <= (s.state == .needs ? needsStaleAfter : staleAfter)
        }
    }

    public static func aggregate(_ sessions: [Session], now: Date = Date()) -> BubbleState {
        live(sessions, now: now).map(\.state).max { $0.priority < $1.priority } ?? .idle
    }

    /// Most urgent first; within a state, the most recent change first.
    public static func sorted(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            a.state.priority != b.state.priority ? a.state.priority > b.state.priority : a.stateSince > b.stateSince
        }
    }
}
