import AppKit
import ClaudeBubbleCore
import Combine
import Foundation
import HookCore

/// The Session Simulator's stress test: many fake agents, each with subagents, sending hook events at a set pace,
/// while the meter reads back what that costs the app. With real files it writes session files the way the hook
/// does (so the watcher, the file reads and everything after them run); in memory it drives the simulator's
/// sessions, for drawing alone.
final class StressRunner: ObservableObject {
    @Published var sessions = 12
    @Published var subagents = 3
    /// Hook events per second, across every session.
    @Published var rate = 20.0
    @Published var writesFiles = true
    @Published private(set) var running = false
    @Published private(set) var report: PerfReport?

    private let simulator: SimulatorModel
    private let directory: URL
    private let queue = DispatchQueue(label: "com.claudebubble.stress")
    private var agents: [StressAgent] = []
    private var records: [[String: Any]] = []
    private var rng = SeededGenerator(seed: 1)
    private var sims: [Int] = []
    private var simSubagents: [Int] = []
    private var events: DispatchSourceTimer?
    private var heartbeat: DispatchSourceTimer?
    private var readout: Timer?
    private var lastBeat = 0.0

    static let prefix = "stress-"

    init(simulator: SimulatorModel, directory: URL = SessionStore.defaultDirectory) {
        self.simulator = simulator
        self.directory = directory
    }

    func start() {
        guard !running else { return }
        running = true
        PerfMeter.shared.recording = true
        let count = sessions, subs = subagents, files = writesFiles, interval = 1 / max(rate, 0.5)
        let made = (0..<count).map { i in
            let name = String(format: "agent-%02d", i + 1)
            return StressAgent(sessionID: Self.prefix + name, cwd: "/stress/\(name)", maxSubagents: subs)
        }
        simulator.reset()
        simulator.showsRealSessions = files
        if files {
            queue.async { [self] in
                agents = made
                records = Array(repeating: [:], count: count)
                rng = SeededGenerator(seed: 1)
            }
        } else {
            agents = made
            rng = SeededGenerator(seed: 1)
            sims = made.map { simulator.add(($0.cwd as NSString).lastPathComponent, state: .idle) }
            simSubagents = Array(repeating: 0, count: count)
        }

        let timer = DispatchSource.makeTimerSource(queue: files ? queue : .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if files { self.writeNextEvent() } else { self.simulateNextEvent() }
            PerfMeter.shared.count(.event)
        }
        timer.resume()
        events = timer

        // The main thread should run this every 10ms; how late it runs is how long it was stuck.
        lastBeat = Self.now()
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        beat.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.now()
            PerfMeter.shared.hitch(max(0, now - self.lastBeat - 0.010))
            self.lastBeat = now
        }
        beat.resume()
        heartbeat = beat

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.report = PerfMeter.shared.report() }
        RunLoop.main.add(tick, forMode: .common)
        readout = tick
    }

    func stop() {
        guard running else { return }
        running = false
        events?.cancel()
        heartbeat?.cancel()
        readout?.invalidate()
        events = nil
        heartbeat = nil
        readout = nil
        PerfMeter.shared.recording = false
        let dir = directory
        queue.async { [self] in
            agents = []
            records = []
            Self.removeFiles(in: dir)
        }
        agents = []
        sims = []
        simulator.reset()
        simulator.showsRealSessions = false
    }

    /// The settings and the last readout, for pasting into a note or an issue.
    func copyReport() {
        let head = "Claude Bubble stress test: \(sessions) sessions × \(subagents) subagents, \(Int(rate)) events/s, "
            + (writesFiles ? "real files" : "in memory")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(head + "\n" + (report?.text ?? "(no readout yet)"), forType: .string)
    }

    /// Stress sessions left behind (a crash mid-run); the app also drops them once their pid is gone.
    static func removeFiles(in dir: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Real files (on `queue`, like hook processes)

    private func writeNextEvent() {
        guard !agents.isEmpty else { return }
        let i = Int.random(in: 0..<agents.count, using: &rng)
        let event = agents[i].next(using: &rng)
        let payload = agents[i].payload(for: event)
        let path = directory.appendingPathComponent(agents[i].sessionID + ".json")
        // Read back what's on disk, as the hook does.
        let previous = (try? Data(contentsOf: path)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? records[i]
        guard case .write(let record) = HookRecorder.record(payload, previous: previous, now: Date().timeIntervalSince1970,
                                                            pid: getpid(), env: .init(replayWindow: 0)),
              JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        records[i] = record
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".tmp-stress-\(UInt64(Date().timeIntervalSince1970 * 1e9))")
        do {
            try data.write(to: tmp, options: .withoutOverwriting)
            if rename(tmp.path, path.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    // MARK: In memory (on main)

    private func simulateNextEvent() {
        guard !agents.isEmpty else { return }
        let i = Int.random(in: 0..<agents.count, using: &rng)
        let id = sims[i]
        switch agents[i].next(using: &rng) {
        case .sessionStart:
            simulator.set(id, .idle)
        case .prompt:
            simulator.set(id, .working)
            simulator.setMotion(id, .generating)
        case let .toolStart(_, tool, agent):
            if agent == nil { simulator.setMotion(id, Motion(rawValue: HookRecorder.motion(for: tool)) ?? .generating) }
        case let .toolEnd(_, _, failed, agent):
            simulator.fire(id, failed ? .fail : .tick)
            if agent == nil {
                simulator.set(id, .working)
                simulator.setMotion(id, .generating)
            }
        case .subagentStart:
            simSubagents[i] += 1
            simulator.setSubagents(id, simSubagents[i])
        case .subagentStop:
            simSubagents[i] = max(0, simSubagents[i] - 1)
            simulator.setSubagents(id, simSubagents[i])
        case .permission:
            simulator.set(id, .needs)
        case .stop:
            simulator.set(id, .idle)
        }
    }

    private static func now() -> Double { CACurrentMediaTime() }
}
