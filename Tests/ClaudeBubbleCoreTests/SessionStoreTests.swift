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
}
