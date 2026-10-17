import XCTest
@testable import HookCore

final class HookRecorderTests: XCTestCase {
    let env = HookRecorder.Environment(replayWindow: 0, subagentTTL: 2700)

    /// Runs events in order through the recorder, like the hook would, returning the last record.
    @discardableResult
    func run(_ events: [[String: Any]], from start: [String: Any]? = nil, now: Double = 1000) -> [String: Any]? {
        var record = start
        for (i, e) in events.enumerated() {
            var e = e
            if e["session_id"] == nil { e["session_id"] = "s" }
            switch HookRecorder.record(e, previous: record ?? [:], now: now + Double(i), pid: 42, env: env) {
            case .write(let r): record = r
            case .delete: record = nil
            case .ignore: break
            }
        }
        return record
    }

    func testStates() {
        XCTAssertEqual(run([["hook_event_name": "SessionStart"]])?["state"] as? String, "idle")
        XCTAssertEqual(run([["hook_event_name": "UserPromptSubmit"]])?["state"] as? String, "working")
        XCTAssertEqual(run([["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "PermissionRequest"]])?["state"] as? String, "needs")
        XCTAssertEqual(run([["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "StopFailure", "error": ["message": "Overloaded"]]])?["detail"] as? String, "Overloaded")
        XCTAssertNil(run([["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "SessionEnd"]]), "SessionEnd deletes")
    }

    func testIgnoresBadSessionIDsAndUnknownEvents() {
        for id in ["", "../x", ".hidden"] {
            guard case .ignore = HookRecorder.record(["hook_event_name": "Stop", "session_id": id], previous: [:], now: 1, pid: 0, env: env) else {
                return XCTFail("\(id) should be ignored")
            }
        }
        guard case .ignore = HookRecorder.record(["hook_event_name": "Whatever", "session_id": "s"], previous: [:], now: 1, pid: 0, env: env) else {
            return XCTFail("unknown event")
        }
    }

    func testPermissionNeedsOutlivesOtherToolsUntilItsOwnResolves() {
        let call: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "rm -rf build", "b": 1]]
        var r = run([["hook_event_name": "UserPromptSubmit"],
                     ["hook_event_name": "PreToolUse", "tool_use_id": "t1"].merging(call) { a, _ in a },
                     ["hook_event_name": "PermissionRequest"].merging(call) { a, _ in a },
                     ["hook_event_name": "PreToolUse", "tool_use_id": "t2", "tool_name": "Read", "agent_id": "sub"],
                     ["hook_event_name": "PostToolUse", "tool_use_id": "t2", "agent_id": "sub"]])
        XCTAssertEqual(r?["state"] as? String, "needs", "another tool finishing doesn't clear the prompt")
        XCTAssertEqual(r?["detail"] as? String, "Approve Bash rm -rf build?")
        r = run([["hook_event_name": "PostToolUse", "tool_use_id": "t1"]], from: r)
        XCTAssertEqual(r?["state"] as? String, "working")
    }

    func testToolFingerprintIgnoresKeyOrder() {
        XCTAssertEqual(HookRecorder.toolKey(["tool_name": "Edit", "tool_input": ["a": 1, "b": [1, 2]]]),
                       HookRecorder.toolKey(["tool_name": "Edit", "tool_input": ["b": [1, 2], "a": 1]]))
        XCTAssertNotEqual(HookRecorder.toolKey(["tool_name": "Edit", "tool_input": ["a": 1]]),
                          HookRecorder.toolKey(["tool_name": "Edit", "tool_input": ["a": 2]]))
    }

    func testDetails() {
        func detail(_ e: [String: Any]) -> String? { run([["hook_event_name": "UserPromptSubmit"], e])?["detail"] as? String }
        XCTAssertEqual(detail(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["description": "Run   the\ntests"]]), "Run the tests")
        XCTAssertEqual(detail(["hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/a/b/View.swift"]]), "Editing View.swift")
        XCTAssertEqual(detail(["hook_event_name": "PreToolUse", "tool_name": "Grep"]), "Reading files")
        XCTAssertEqual(detail(["hook_event_name": "PreToolUse", "tool_name": "mcp__x__y"]), "Using mcp__x__y")
        let long = String(repeating: "word ", count: 30)
        let clipped = detail(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["description": long]])
        XCTAssertEqual(clipped?.count, 60)
        XCTAssertEqual(clipped?.last, "\u{2026}")
        XCTAssertEqual(run([["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "Stop"]])?["detail"] as? String, "Completed")
    }

    func testMotionFollowsTheMainAgentsToolsInFlight() {
        var r = run([["hook_event_name": "UserPromptSubmit"],
                     ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_use_id": "a"],
                     ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "b"]])
        XCTAssertEqual(r?["activity"] as? String, "bash")
        r = run([["hook_event_name": "PostToolUse", "tool_use_id": "b"]], from: r)
        XCTAssertEqual(r?["activity"] as? String, "read", "back to what's still running")
        r = run([["hook_event_name": "PreToolUse", "tool_name": "WebFetch", "tool_use_id": "c", "agent_id": "sub"]], from: r)
        XCTAssertEqual(r?["activity"] as? String, "read", "a subagent's tools don't move the main orb")
        r = run([["hook_event_name": "PostToolUse", "tool_use_id": "a"]], from: r)
        XCTAssertEqual(r?["activity"] as? String, "generating")
        XCTAssertEqual(r?["ticks"] as? Int, 2)
    }

    func testSubagentsExpireAndSurviveStop() {
        var r = run([["hook_event_name": "UserPromptSubmit"], ["hook_event_name": "SubagentStart", "agent_id": "x"],
                     ["hook_event_name": "Stop"]])
        XCTAssertEqual((r?["subagents"] as? [String: Any])?.count, 1, "background agents outlive Stop")
        r = run([["hook_event_name": "PreToolUse", "tool_name": "Read"]], from: r, now: 1000 + 3000)
        XCTAssertEqual((r?["subagents"] as? [String: Any])?.count, 0, "one whose stop never came expires")
    }

    func testReplayWindowIgnoresEventsBeforeThePrompt() {
        let windowed = HookRecorder.Environment(replayWindow: 3, subagentTTL: 2700)
        guard case .write(let start) = HookRecorder.record(["hook_event_name": "SessionStart", "session_id": "s"], previous: [:], now: 100, pid: 0, env: windowed) else {
            return XCTFail()
        }
        guard case .ignore = HookRecorder.record(["hook_event_name": "PermissionRequest", "session_id": "s"], previous: start, now: 101, pid: 0, env: windowed) else {
            return XCTFail("replayed event inside the window")
        }
    }

    func testReadsTheOlderHooksRecords() {
        // The Python hook kept tool_ids as an object and subagents possibly as a list.
        let old: [String: Any] = ["state": "working", "prompted": true, "started_at": 1.0, "tool_ids": ["k": "t9"],
                                  "subagents": ["a", "b"], "ticks": 3]
        let r = run([["hook_event_name": "PostToolUse"]], from: old)
        XCTAssertEqual(r?["ticks"] as? Int, 4)
        XCTAssertEqual((r?["subagents"] as? [String: Any])?.count, 2)
        XCTAssertNotNil(r?["tool_ids"] as? [[String]])
    }

    func testRecordRoundTripsThroughJSON() throws {
        let r = try XCTUnwrap(run([["hook_event_name": "UserPromptSubmit", "cwd": "/Users/x/proj", "transcript_path": "/t.jsonl"]]))
        let data = try JSONSerialization.data(withJSONObject: r)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(back["project"] as? String, "proj")
        XCTAssertEqual(back["pid"] as? Int, 42)
        XCTAssertEqual(back["transcript"] as? String, "/t.jsonl")
        XCTAssertEqual(back["prompted"] as? Bool, true)
    }

    func testSurvivesNonsenseInTheSessionFile() {
        // A huge or non-numeric counter must not crash the hook (it would fail every event for that session).
        let bad: [String: Any] = ["state": "working", "prompted": true, "ticks": 1e300, "fails": "inf", "skills": -1e300,
                                  "started_at": "nan", "state_since": "x"]
        let r = run([["hook_event_name": "PostToolUse"]], from: bad)
        XCTAssertEqual(r?["ticks"] as? Int, 1)
        XCTAssertEqual(r?["fails"] as? Int, 0)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r ?? [:]), "writable as JSON")
    }
}
