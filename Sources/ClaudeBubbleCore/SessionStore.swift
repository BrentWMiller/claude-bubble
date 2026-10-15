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
    /// Claude Code's own title for the session, when it has one.
    public let title: String?

    /// What to call the session: Claude Code's title, else the project folder.
    public var displayName: String { title ?? project }

    public init(id: String, state: BubbleState, cwd: String = "", updatedAt: Date,
                project: String? = nil, detail: String = "", stateSince: Date? = nil, pid: Int32? = nil,
                title: String? = nil) {
        self.id = id
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.project = project ?? Session.projectName(for: cwd)
        self.detail = detail
        self.stateSince = stateSince ?? updatedAt
        self.pid = pid
        self.title = title
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

    /// Whether `pid` is still the process that wrote this session. A pid the kernel has reused for a
    /// process started after the session's last event is not. Unknown (lookup failed) counts as alive.
    public static func processIsAlive(_ pid: Int32, lastSeen: Date) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return true }
        guard size > 0 else { return false }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        return started <= lastSeen.addingTimeInterval(1)
    }

    public static func load(from dir: URL, now: Date = Date(),
                            isAlive: (Int32, Date) -> Bool = processIsAlive(_:lastSeen:)) -> [Session] {
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
            if let pid, !isAlive(pid, updated) {
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

    /// Sessions worth showing. A live process keeps its session listed, but a busy state that has gone
    /// quiet past the staleness limit shows as idle (Esc interrupts never fire Stop). Without a pid,
    /// stale sessions drop out entirely.
    public static func live(_ sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.compactMap { s in
            let limit = s.state == .needs ? needsStaleAfter : staleAfter
            guard now.timeIntervalSince(s.updatedAt) > limit, s.state != .idle else { return s }
            guard s.pid != nil else { return nil }
            return Session(id: s.id, state: .idle, cwd: s.cwd, updatedAt: s.updatedAt,
                           project: s.project, detail: "Idle", stateSince: s.updatedAt, pid: s.pid, title: s.title)
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

    /// Adds Claude Code's session titles, and its own status line while a session is working and that
    /// line was written during the current state. Needs/error keep the hook's more specific text.
    public static func withJobs(_ sessions: [Session], from jobsDir: URL = JobStore.defaultDirectory) -> [Session] {
        sessions.map { s in
            guard let job = JobStore.load(sessionId: s.id, from: jobsDir) else { return s }
            let name = job.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (name?.isEmpty ?? true) ? nil : name
            var detail = s.detail
            if s.state == .working, job.state == "working",
               let summary = job.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
               let written = job.updatedAt, written >= s.stateSince.addingTimeInterval(-5) {
                detail = summary
            }
            return Session(id: s.id, state: s.state, cwd: s.cwd, updatedAt: s.updatedAt, project: s.project,
                           detail: detail, stateSince: s.stateSince, pid: s.pid, title: title)
        }
    }
}
