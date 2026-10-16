import Foundation

/// What a session is doing for the orb's motion and layers (written by the hook).
public struct SessionActivity: Equatable, Sendable {
    public var motion: Motion
    /// When the current motion began (bash settles with it).
    public var since: Date?
    public var subagents: Int
    /// Running counters; the app fires a layer when one goes up.
    public var ticks, fails, skills: Int

    public init(motion: Motion = .generating, since: Date? = nil, subagents: Int = 0,
                ticks: Int = 0, fails: Int = 0, skills: Int = 0) {
        self.motion = motion
        self.since = since
        self.subagents = subagents
        self.ticks = ticks
        self.fails = fails
        self.skills = skills
    }
}

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
    /// False until the user's first prompt; unused sessions (e.g. pre-warmed spares) aren't shown.
    public let prompted: Bool
    /// Current context size, from Claude Code's job file.
    public let tokens: Int?
    /// Finished with an open pull request: "Ready for review" (orange), like Claude Code's agents view.
    public let reviewReady: Bool
    /// The orb's motion and layer counters.
    public var activity = SessionActivity()

    /// What to call the session: Claude Code's title, else the project folder.
    public var displayName: String { title ?? project }

    public init(id: String, state: BubbleState, cwd: String = "", updatedAt: Date,
                project: String? = nil, detail: String = "", stateSince: Date? = nil, pid: Int32? = nil,
                title: String? = nil, prompted: Bool = true, tokens: Int? = nil, reviewReady: Bool = false) {
        self.id = id
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.project = project ?? Session.projectName(for: cwd)
        self.detail = detail
        self.stateSince = stateSince ?? updatedAt
        self.pid = pid
        self.title = title
        self.prompted = prompted
        self.tokens = tokens
        self.reviewReady = reviewReady
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
        let prompted: Bool?
        let activity: String?
        let activity_since: Double?
        let ticks: Int?
        let fails: Int?
        let skills: Int?
        let subagents: [String]?
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
            var session = Session(id: String(name.dropLast(5)), state: state, cwd: record.cwd ?? "", updatedAt: updated,
                                  project: record.project, detail: record.detail ?? "",
                                  stateSince: record.state_since.map(Date.init(timeIntervalSince1970:)), pid: pid,
                                  prompted: record.prompted ?? true)
            session.activity = SessionActivity(motion: record.activity.flatMap(Motion.init(rawValue:)) ?? .generating,
                                               since: record.activity_since.map(Date.init(timeIntervalSince1970:)),
                                               subagents: record.subagents?.count ?? 0, ticks: record.ticks ?? 0,
                                               fails: record.fails ?? 0, skills: record.skills ?? 0)
            sessions.append(session)
        }
        return sessions
    }

    /// Sessions worth showing. Never-prompted sessions (pre-warmed spares, untouched launches) are
    /// hidden, matching Claude Code's agents view. A live process keeps its session listed, but a busy
    /// state gone quiet past the staleness limit shows as idle (Esc interrupts never fire Stop).
    /// Without a pid, any stale session drops out.
    public static func live(_ sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.compactMap { s in
            guard s.prompted else { return nil }
            let limit = s.state == .needs ? needsStaleAfter : staleAfter
            guard now.timeIntervalSince(s.updatedAt) > limit else { return s }
            guard s.pid != nil else { return nil }
            guard s.state != .idle else { return s }
            var quiet = Session(id: s.id, state: .idle, cwd: s.cwd, updatedAt: s.updatedAt, project: s.project,
                                detail: "Idle", stateSince: s.updatedAt, pid: s.pid, title: s.title, prompted: s.prompted,
                                tokens: s.tokens, reviewReady: s.reviewReady)
            quiet.activity = s.activity
            return quiet
        }
    }

    /// The session whose motion the orb shows: the working one that changed most recently.
    public static func motionFocus(_ sessions: [Session]) -> Session? {
        sessions.filter { $0.state == .working }.max { $0.updatedAt < $1.updatedAt }
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

    /// Adds what Claude Code's job files know: session titles, its own status line while working, "Ready for
    /// review" (finished with a PR), and "Needs input" (the turn ended on a question). Needs/error from the hook
    /// keep its more specific text.
    public static func withJobs(_ sessions: [Session], from jobsDir: URL = JobStore.defaultDirectory) -> [Session] {
        sessions.map { s in
            guard let job = JobStore.load(sessionId: s.id, from: jobsDir) else { return s }
            let name = job.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (name?.isEmpty ?? true) ? nil : name
            var detail = s.detail
            // The turn ended on a question Claude is waiting for you to answer: the job says "blocked"
            // (the agents view's "Needs input"), even though the hook only saw a Stop.
            let awaitingAnswer = s.state == .idle && job.state == "blocked"
            if awaitingAnswer {
                let question = job.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                detail = question.isEmpty ? "Needs input" : question
            }
            if s.state == .working, job.state == "working",
               let summary = job.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
               let written = job.updatedAt, written >= s.stateSince.addingTimeInterval(-5) {
                detail = summary
            }
            var joined = Session(id: s.id, state: awaitingAnswer ? .needs : s.state, cwd: s.cwd, updatedAt: s.updatedAt,
                                 project: s.project, detail: detail, stateSince: s.stateSince, pid: s.pid, title: title,
                                 prompted: s.prompted, tokens: job.tokens,
                                 reviewReady: s.state == .idle && !awaitingAnswer && job.hasPullRequest)
            joined.activity = s.activity
            return joined
        }
    }
}
