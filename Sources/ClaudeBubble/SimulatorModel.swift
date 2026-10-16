import ClaudeBubbleCore
import Combine
import Foundation

/// Fake sessions for the Session Simulator. While its window is open they replace the real sessions
/// everywhere (orb, pips, list); they never touch the session files.
final class SimulatorModel: ObservableObject {
    struct Sim: Identifiable, Equatable {
        let id: Int
        let name: String
        var state: BubbleState
        var since: Date
        /// Finished with an open PR ("Ready for review").
        var review = false
        /// The orb's motion and layers for this session (used while working).
        var motion: Motion = .generating
        var motionSince = Date()
        var subagents = 0
        var ticks = 0, fails = 0, skills = 0
        /// Last change; the orb follows the most recently changed working session.
        var changed = Date()
    }

    @Published private(set) var sessions: [Sim] = []
    @Published var isOpen = false
    /// Stands in for the real usage reading while on.
    @Published var usageActive = false { didSet { if usageActive && !oldValue { windowEnds = Date().addingTimeInterval(72 * 60) } } }
    /// Percent of the window left.
    @Published var usageLeft: Double = 100
    @Published private(set) var windowEnds = Date().addingTimeInterval(72 * 60)
    private var nextId = 0
    private var storyWork: [DispatchWorkItem] = []

    @discardableResult
    func add(_ name: String? = nil, state: BubbleState = .working) -> Int {
        let id = nextId
        nextId += 1
        let pool = SimulatorStory.namePool
        sessions.append(Sim(id: id, name: name ?? pool[id % pool.count], state: state, since: Date()))
        return id
    }

    func set(_ id: Int, _ state: BubbleState, review: Bool = false) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].state != state || sessions[i].review != review else { return }
        if sessions[i].state != state { sessions[i].since = Date() }
        sessions[i].state = state
        sessions[i].review = review && state == .idle
        sessions[i].changed = Date()
    }

    func setMotion(_ id: Int, _ motion: Motion) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].motion != motion else { return }
        sessions[i].motion = motion
        sessions[i].motionSince = Date()
        sessions[i].changed = Date()
    }

    func setSubagents(_ id: Int, _ n: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].subagents = min(max(n, 0), 6)
        sessions[i].changed = Date()
    }

    enum Layer { case tick, fail, skill }

    func fire(_ id: Int, _ layer: Layer) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        switch layer {
        case .tick: sessions[i].ticks += 1
        case .fail: sessions[i].fails += 1
        case .skill: sessions[i].skills += 1
        }
        sessions[i].changed = Date()
    }

    /// The design's scripted session (Orb States): about 40 seconds of reads, searches, edits, a failing then
    /// passing test run, a web fetch, an MCP call, subagents, compaction, and the finish.
    func playSession() {
        reset()
        usageActive = true
        let id = add("auth-refactor", state: .working)
        var t = 0.0
        for step in SimulatorStory.session {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // The previous step's tool finishing.
                if let prior = step.endsPrevious { self.fire(id, prior == .failed ? .fail : .tick) }
                if step.skill { self.fire(id, .skill) }
                self.setSubagents(id, step.subagents)
                self.set(id, step.state)
                self.setMotion(id, step.motion)
                if step.resetsUsage { self.resetWindow() }
                if let left = step.usageLeft { self.usageLeft = left }
            }
            storyWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: work)
            t += step.duration
        }
    }

    func remove(_ id: Int) {
        sessions.removeAll { $0.id == id }
    }

    func reset() {
        storyWork.forEach { $0.cancel() }
        storyWork = []
        sessions = []
        nextId = 0
    }

    /// The design's scripted 14-second story.
    func playStory() {
        reset()
        var added: [Int] = []
        for step in SimulatorStory.steps {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                switch step.action {
                case let .add(name, state): added.append(self.add(name, state: state))
                case let .set(index, state) where added.indices.contains(index): self.set(added[index], state)
                case .set: break
                }
            }
            storyWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + step.at, execute: work)
        }
    }

    /// Starts a fresh 5-hour window at 100% left (announced as "refreshed" if this one warned).
    func resetWindow() {
        usageLeft = 100
        windowEnds = Date().addingTimeInterval(5 * 3600)
    }

    var usageReading: UsageReading? {
        usageActive ? UsageReading(usedPercent: 100 - usageLeft, resetsAt: windowEnds, capturedAt: windowEnds) : nil
    }

    /// As real-looking sessions, for the rest of the app.
    var asSessions: [Session] {
        sessions.map {
            var s = Session(id: "sim-\($0.id)", state: $0.state, updatedAt: $0.changed, project: $0.name,
                            detail: SimulatorStory.detail(for: $0.state), stateSince: $0.since, title: $0.name, reviewReady: $0.review)
            s.activity = SessionActivity(motion: $0.motion, since: $0.motionSince, subagents: $0.subagents,
                                         ticks: $0.ticks, fails: $0.fails, skills: $0.skills)
            return s
        }
    }
}
