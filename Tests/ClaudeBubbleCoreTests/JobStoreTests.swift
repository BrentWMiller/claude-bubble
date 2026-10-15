import XCTest
@testable import ClaudeBubbleCore

final class JobStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let sid = "6d862ee9-15fc-42aa-bcef-b79d03c0d017"
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func writeJob(_ json: String, folder: String = "6d862ee9") throws {
        let jobDir = dir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try json.write(to: jobDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
    }

    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // Pip colors match what the orb looks like, not its first palette entry.
    func testWorkingSwatchIsViolet() {
        let c = BubbleState.working.swatch
        XCTAssertGreaterThan(c.z, c.x, "working should read violet (blue over red)")
        XCTAssertGreaterThan(c.z, c.y)
    }

    func testOtherSwatchesKeepTheirOrbColor() {
        XCTAssertGreaterThan(BubbleState.needs.swatch.x, BubbleState.needs.swatch.z, "needs is amber")
        XCTAssertGreaterThan(BubbleState.error.swatch.x, 0.9, "error is red")
        XCTAssertLessThan(BubbleState.error.swatch.y, 0.3)
    }

    func testColorsMatchTheAgentsView() {
        let idle = BubbleState.idle.swatch, needs = BubbleState.needs.swatch
        XCTAssertGreaterThan(idle.y, idle.x, "idle/completed reads green")
        XCTAssertGreaterThan(idle.y, idle.z)
        XCTAssertGreaterThan(needs.x, 0.9, "needs reads yellow")
        XCTAssertGreaterThan(needs.y, 0.75)
        XCTAssertLessThan(needs.z, 0.4)
    }

    // JobStore.load
    func testReadsNameDetailAndState() throws {
        try writeJob(#"{"sessionId":"\#(sid)","name":"Claude status bubble app","detail":"fixing 4 review findings","state":"working","updatedAt":"\#(iso(now))"}"#)
        let job = try XCTUnwrap(JobStore.load(sessionId: sid, from: dir))
        XCTAssertEqual(job.name, "Claude status bubble app")
        XCTAssertEqual(job.detail, "fixing 4 review findings")
        XCTAssertEqual(job.state, "working")
        XCTAssertEqual(try XCTUnwrap(job.updatedAt).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.01)
    }

    func testIgnoresAJobForAnotherSession() throws {
        try writeJob(#"{"sessionId":"6d862ee9-ffff-0000-0000-000000000000","name":"Other"}"#)
        XCTAssertNil(JobStore.load(sessionId: sid, from: dir))
    }

    func testMissingOrCorruptJobIsNil() throws {
        XCTAssertNil(JobStore.load(sessionId: sid, from: dir))
        try writeJob("{ nope")
        XCTAssertNil(JobStore.load(sessionId: sid, from: dir))
        XCTAssertNil(JobStore.load(sessionId: "", from: dir))
    }

    // SessionStore.withJobs
    func session(_ state: BubbleState, detail: String = "Running tests", since: Date? = nil) -> Session {
        Session(id: sid, state: state, cwd: "/code/web-app", updatedAt: now, detail: detail, stateSince: since ?? now.addingTimeInterval(-60))
    }

    func testWorkingSessionTakesTheJobTitleAndFreshDetail() throws {
        try writeJob(#"{"sessionId":"\#(sid)","name":"Claude status bubble app","detail":"fixing 4 review findings","state":"working","updatedAt":"\#(iso(now))"}"#)
        let s = try XCTUnwrap(SessionStore.withJobs([session(.working)], from: dir).first)
        XCTAssertEqual(s.displayName, "Claude status bubble app")
        XCTAssertEqual(s.detail, "fixing 4 review findings")
    }

    func testNeedsKeepsTheHookPrompt() throws {
        try writeJob(#"{"sessionId":"\#(sid)","name":"Claude status bubble app","detail":"fixing things","state":"working","updatedAt":"\#(iso(now))"}"#)
        let s = try XCTUnwrap(SessionStore.withJobs([session(.needs, detail: "Approve Edit auth.ts?")], from: dir).first)
        XCTAssertEqual(s.displayName, "Claude status bubble app")
        XCTAssertEqual(s.detail, "Approve Edit auth.ts?")
    }

    func testStaleJobDetailIsIgnored() throws {
        try writeJob(#"{"sessionId":"\#(sid)","name":"Claude status bubble app","detail":"old summary","state":"working","updatedAt":"\#(iso(now.addingTimeInterval(-600)))"}"#)
        let s = try XCTUnwrap(SessionStore.withJobs([session(.working)], from: dir).first)
        XCTAssertEqual(s.detail, "Running tests")
    }

    func testNoJobFallsBackToTheProjectFolder() {
        let s = SessionStore.withJobs([session(.working)], from: dir).first
        XCTAssertEqual(s?.displayName, "web-app")
        XCTAssertEqual(s?.detail, "Running tests")
    }

    func testBlankJobNameFallsBack() throws {
        try writeJob(#"{"sessionId":"\#(sid)","name":"  ","state":"working"}"#)
        XCTAssertEqual(SessionStore.withJobs([session(.working)], from: dir).first?.displayName, "web-app")
    }
}
