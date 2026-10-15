import XCTest
@testable import ClaudeBubbleCore

final class DailyActivityTests: XCTestCase {
    // 2026-10-15 00:00 local, built from components so the test is timezone-safe.
    let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    func at(_ h: Double) -> Date { midnight.addingTimeInterval(h * 3600) }
    typealias Entry = DailyActivity.Entry

    // Formatting
    func testTokenFormat() {
        XCTAssertEqual(TokenFormat.string(950), "950")
        XCTAssertEqual(TokenFormat.string(12_340), "12.3k")
        XCTAssertEqual(TokenFormat.string(12_000), "12k")
        XCTAssertEqual(TokenFormat.string(390_494), "390k")
        XCTAssertEqual(TokenFormat.string(1_234_567), "1.2M")
    }

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.string(0), "0m")
        XCTAssertEqual(DurationFormat.string(45 * 60), "45m")
        XCTAssertEqual(DurationFormat.string(2 * 3600 + 14 * 60 + 30), "2h 14m")
        XCTAssertEqual(DurationFormat.string(3 * 3600), "3h 0m")
    }

    // Timeline math
    func testSumsWorkingStretches() {
        let entries = [Entry(at: at(9), state: "working"), Entry(at: at(9.5), state: "done"),
                       Entry(at: at(10), state: "working"), Entry(at: at(10.25), state: "blocked")]
        XCTAssertEqual(DailyActivity.workingTime(entries, since: midnight, now: at(12)), 45 * 60, accuracy: 0.5)
    }

    func testStretchCrossingMidnightIsCut() {
        let entries = [Entry(at: at(-0.5), state: "working"), Entry(at: at(0.5), state: "done")]
        XCTAssertEqual(DailyActivity.workingTime(entries, since: midnight, now: at(12)), 30 * 60, accuracy: 0.5)
        XCTAssertTrue(DailyActivity.wasActive(entries, since: midnight))
    }

    func testStillWorkingCountsUpToNow() {
        let entries = [Entry(at: at(11.75), state: "working")]
        XCTAssertEqual(DailyActivity.workingTime(entries, since: midnight, now: at(12)), 15 * 60, accuracy: 0.5)
    }

    func testRepeatedWorkingEntriesDontDoubleCount() {
        let entries = [Entry(at: at(9), state: "working"), Entry(at: at(9.25), state: "working"), Entry(at: at(9.5), state: "done")]
        XCTAssertEqual(DailyActivity.workingTime(entries, since: midnight, now: at(12)), 30 * 60, accuracy: 0.5)
    }

    func testYesterdayOnlyIsInactive() {
        let entries = [Entry(at: at(-5), state: "working"), Entry(at: at(-4), state: "done")]
        XCTAssertEqual(DailyActivity.workingTime(entries, since: midnight, now: at(12)), 0)
        XCTAssertFalse(DailyActivity.wasActive(entries, since: midnight))
    }

    // Reading job folders
    func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    func testSummaryAcrossJobFoldersSkipsJunk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        func job(_ name: String, _ lines: [String]) throws {
            let d = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: d.appendingPathComponent("timeline.jsonl"), atomically: true, encoding: .utf8)
        }
        try job("aaaa1111", [#"{"at":"\#(iso(at(9)))","state":"working"}"#, "not json", #"{"at":"\#(iso(at(10)))","state":"done"}"#])
        try job("bbbb2222", [#"{"at":"\#(iso(at(11)))","state":"working"}"#])
        try job("cccc3333", [#"{"at":"\#(iso(at(-3)))","state":"done"}"#])
        try "{}".write(to: dir.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)

        let summary = DailyActivity.summary(jobsDir: dir, since: midnight, now: at(11.5))
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.working, 90 * 60, accuracy: 1)
    }

    func testJobTokensReachTheSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sid = "6d862ee9-15fc-42aa-bcef-b79d03c0d017"
        let jobDir = dir.appendingPathComponent("6d862ee9")
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try #"{"sessionId":"\#(sid)","tokens":390494}"#.write(to: jobDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(JobStore.load(sessionId: sid, from: dir)?.tokens, 390_494)
        let s = Session(id: sid, state: .working, updatedAt: at(1))
        XCTAssertEqual(SessionStore.withJobs([s], from: dir).first?.tokens, 390_494)
    }
}
