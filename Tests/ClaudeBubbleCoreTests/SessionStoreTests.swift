import XCTest
@testable import ClaudeBubbleCore

final class SessionStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func session(_ state: BubbleState, ageMinutes: Double = 0) -> Session {
        Session(id: UUID().uuidString, state: state, updatedAt: now.addingTimeInterval(-ageMinutes * 60))
    }

    func testNoSessionsIsIdle() {
        XCTAssertEqual(SessionStore.aggregate([], now: now), .idle)
    }

    func testPriorityErrorOverNeedsOverWorkingOverIdle() {
        XCTAssertEqual(SessionStore.aggregate([session(.idle), session(.working)], now: now), .working)
        XCTAssertEqual(SessionStore.aggregate([session(.working), session(.needs), session(.idle)], now: now), .needs)
        XCTAssertEqual(SessionStore.aggregate([session(.needs), session(.error), session(.working)], now: now), .error)
    }

    func testStaleWorkingIsIgnored() {
        XCTAssertEqual(SessionStore.aggregate([session(.working, ageMinutes: 16)], now: now), .idle)
        XCTAssertEqual(SessionStore.aggregate([session(.working, ageMinutes: 14)], now: now), .working)
    }

    func testNeedsStaysLiveForAnHour() {
        XCTAssertEqual(SessionStore.aggregate([session(.needs, ageMinutes: 30)], now: now), .needs)
        XCTAssertEqual(SessionStore.aggregate([session(.needs, ageMinutes: 61)], now: now), .idle)
    }

    func testLoadReadsValidFilesAndSkipsJunk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = now.timeIntervalSince1970
        try #"{"state":"working","cwd":"/x","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("good.json"), atomically: true, encoding: .utf8)
        try "{not json".write(to: dir.appendingPathComponent("corrupt.json"), atomically: true, encoding: .utf8)
        try #"{"state":"dancing","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("unknown.json"), atomically: true, encoding: .utf8)
        try #"{"state":"needs","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent(".tmp-abc"), atomically: true, encoding: .utf8)
        try #"{"state":"needs","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let sessions = SessionStore.load(from: dir, now: now)

        XCTAssertEqual(sessions, [Session(id: "good", state: .working, cwd: "/x", updatedAt: now)])
    }

    func testLoadDeletesFilesOlderThanADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json")
        try #"{"state":"idle","updated_at":\#(now.timeIntervalSince1970 - 25 * 3600)}"#.write(to: old, atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionStore.load(from: dir, now: now), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testLoadFromMissingDirectoryIsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(SessionStore.load(from: dir, now: now), [])
    }

    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOlderFilesDecodeWithDefaults() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"state":"idle","cwd":"/code/api-server","updated_at":\#(now.timeIntervalSince1970)}"#
            .write(to: dir.appendingPathComponent("old.json"), atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(SessionStore.load(from: dir, now: now).first)
        XCTAssertEqual(s.project, "api-server")
        XCTAssertEqual(s.detail, "")
        XCTAssertEqual(s.stateSince, now)
        XCTAssertNil(s.pid)
    }

    func testReadsNewFields() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = now.timeIntervalSince1970
        try #"{"state":"needs","cwd":"/x","updated_at":\#(t),"project":"web-app","detail":"Approve Edit auth.ts?","state_since":\#(t - 42),"pid":777}"#
            .write(to: dir.appendingPathComponent("n.json"), atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(SessionStore.load(from: dir, now: now, isAlive: { _, _ in true }).first)
        XCTAssertEqual(s.project, "web-app")
        XCTAssertEqual(s.detail, "Approve Edit auth.ts?")
        XCTAssertEqual(s.stateSince, now.addingTimeInterval(-42))
        XCTAssertEqual(s.pid, 777)
    }

    func testDeadPidIsDroppedAndDeleted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dead.json")
        try #"{"state":"working","updated_at":\#(now.timeIntervalSince1970),"pid":999}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStore.load(from: dir, now: now, isAlive: { _, _ in false }), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLivePidSurvivesTheDayOldCleanup() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"state":"idle","updated_at":\#(now.timeIntervalSince1970 - 25 * 3600),"pid":5}"#
            .write(to: dir.appendingPathComponent("idle.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStore.load(from: dir, now: now, isAlive: { _, _ in true }).count, 1)
    }

    func testLivePidKeepsAStaleSessionListedButIdle() {
        let stuck = Session(id: "a", state: .working, updatedAt: now.addingTimeInterval(-2 * 3600), detail: "Running tests", pid: 5)
        let shown = SessionStore.live([stuck], now: now)
        XCTAssertEqual(shown.map(\.id), ["a"])
        XCTAssertEqual(shown.first?.state, .idle)
        XCTAssertEqual(shown.first?.detail, "Idle")
        XCTAssertEqual(SessionStore.aggregate([stuck], now: now), .idle)
    }

    func testLivePidFreshWorkStaysWorking() {
        let s = Session(id: "a", state: .working, updatedAt: now.addingTimeInterval(-60), pid: 5)
        XCTAssertEqual(SessionStore.live([s], now: now), [s])
    }

    func testLivePidNeedsGetsTheLongerWindow() {
        let s = Session(id: "a", state: .needs, updatedAt: now.addingTimeInterval(-30 * 60), pid: 5)
        XCTAssertEqual(SessionStore.live([s], now: now).first?.state, .needs)
    }

    func testSortedByUrgencyThenMostRecentChange() {
        let idle = Session(id: "i", state: .idle, updatedAt: now)
        let oldWork = Session(id: "w1", state: .working, updatedAt: now, stateSince: now.addingTimeInterval(-300))
        let newWork = Session(id: "w2", state: .working, updatedAt: now, stateSince: now.addingTimeInterval(-10))
        let needs = Session(id: "n", state: .needs, updatedAt: now)
        let error = Session(id: "e", state: .error, updatedAt: now)
        XCTAssertEqual(SessionStore.sorted([idle, oldWork, needs, newWork, error]).map(\.id), ["e", "n", "w2", "w1", "i"])
    }

    func testProcessIsAliveForThisProcessOnly() {
        XCTAssertTrue(SessionStore.processIsAlive(getpid(), lastSeen: Date()))
        XCTAssertFalse(SessionStore.processIsAlive(99_999_999, lastSeen: Date()))
    }

    func testReusedPidIsNotTheSessionsProcess() {
        // This process started after 1970, so it can't have written an event back then.
        XCTAssertFalse(SessionStore.processIsAlive(getpid(), lastSeen: Date(timeIntervalSince1970: 1000)))
    }

    func testNeverPromptedSessionsAreHidden() {
        let spare = Session(id: "spare", state: .idle, updatedAt: now, pid: 5, prompted: false)
        let real = Session(id: "real", state: .working, updatedAt: now, pid: 6)
        XCTAssertEqual(SessionStore.live([spare, real], now: now).map(\.id), ["real"])
    }

    func testIdleSessionWithoutPidAgesOut() {
        let old = Session(id: "old", state: .idle, updatedAt: now.addingTimeInterval(-20 * 60))
        XCTAssertEqual(SessionStore.live([old], now: now), [])
    }

    func testLoadReadsPromptedAndDefaultsToTrue() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = now.timeIntervalSince1970
        try #"{"state":"idle","updated_at":\#(t),"prompted":false}"#.write(to: dir.appendingPathComponent("a.json"), atomically: true, encoding: .utf8)
        try #"{"state":"idle","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        let byId = Dictionary(uniqueKeysWithValues: SessionStore.load(from: dir, now: now).map { ($0.id, $0.prompted) })
        XCTAssertEqual(byId["a"], false)
        XCTAssertEqual(byId["b"], true)
    }
}
