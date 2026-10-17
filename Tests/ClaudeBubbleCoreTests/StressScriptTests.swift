import XCTest
@testable import HookCore

final class StressScriptTests: XCTestCase {
    let env = HookRecorder.Environment(replayWindow: 0, subagentTTL: 2700)

    /// Plays `count` events from one agent through the recorder, like the hook would.
    func play(_ count: Int, subagents: Int = 3, seed: UInt64 = 7) -> (events: [StressEvent], records: [[String: Any]]) {
        var agent = StressAgent(sessionID: "stress-01", cwd: "/stress/agent-01", maxSubagents: subagents)
        var rng = SeededGenerator(seed: seed)
        var record: [String: Any] = [:]
        var events: [StressEvent] = [], records: [[String: Any]] = []
        for i in 0..<count {
            let event = agent.next(using: &rng)
            events.append(event)
            if case .write(let r) = HookRecorder.record(agent.payload(for: event), previous: record, now: 1000 + Double(i), pid: 42, env: env) {
                record = r
                records.append(r)
            }
        }
        return (events, records)
    }

    func testStartsAndThenPrompts() {
        let events = play(2).events
        XCTAssertEqual(events.first, .sessionStart)
        XCTAssertEqual(events.dropFirst().first, .prompt)
    }

    func testSeededRunsRepeat() {
        XCTAssertEqual(play(300, seed: 3).events, play(300, seed: 3).events)
        XCTAssertNotEqual(play(300, seed: 3).events, play(300, seed: 4).events)
    }

    func testToolCallsPairUp() {
        var open: Set<String> = []
        for event in play(2000).events {
            switch event {
            case let .toolStart(id, _, _): XCTAssertTrue(open.insert(id).inserted, "\(id) started twice")
            case let .toolEnd(id, _, _, _): XCTAssertNotNil(open.remove(id), "\(id) ended without starting")
            case .stop: XCTAssertTrue(open.isEmpty, "stopped with \(open) running")
            default: break
            }
        }
    }

    func testSubagentsStayUnderTheCap() {
        var running: Set<String> = []
        for event in play(2000, subagents: 2).events {
            switch event {
            case .subagentStart(let id): running.insert(id)
            case .subagentStop(let id): XCTAssertNotNil(running.remove(id))
            case let .toolStart(_, _, agent?): XCTAssertTrue(running.contains(agent), "tool from a stopped subagent")
            default: break
            }
            XCTAssertLessThanOrEqual(running.count, 2)
        }
        XCTAssertTrue(play(2000, subagents: 0).events.allSatisfy { if case .subagentStart = $0 { false } else { true } })
    }

    // The hook turns the script into every state the app shows.
    func testCoversEveryState() {
        let states = Set(play(2000).records.compactMap { $0["state"] as? String })
        XCTAssertEqual(states, ["idle", "working", "needs"])
        XCTAssertTrue(play(2000).records.contains { (($0["subagents"] as? [String: Any])?.count ?? 0) > 0 })
    }
}
