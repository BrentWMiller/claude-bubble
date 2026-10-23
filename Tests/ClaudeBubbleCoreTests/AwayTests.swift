import XCTest
@testable import ClaudeBubbleCore

final class AwayTests: XCTestCase {
    func testLeavesAfterThresholdAndBacksOnInput() {
        var t = AwayTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNil(t.update(idle: 30, threshold: 600, inactive: false, now: t0))
        XCTAssertEqual(t.update(idle: 601, threshold: 600, inactive: false, now: t0), .left(at: t0.addingTimeInterval(-601)))
        XCTAssertNil(t.update(idle: 900, threshold: 600, inactive: false, now: t0))
        XCTAssertEqual(t.update(idle: 1, threshold: 600, inactive: false, now: t0), .back(leftAt: t0.addingTimeInterval(-601)))
    }

    func testLockIsAwayAtOnce() {
        var t = AwayTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(t.update(idle: 0, threshold: 600, inactive: true, now: t0), .left(at: t0))
        XCTAssertNil(t.update(idle: 0, threshold: 600, inactive: true, now: t0.addingTimeInterval(60)))
        XCTAssertEqual(t.update(idle: 0, threshold: 600, inactive: false, now: t0.addingTimeInterval(120)), .back(leftAt: t0))
    }

    func testUnseenCatchUpKeepsFirstLeave() {
        var t = AwayTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = t.update(idle: 0, threshold: 600, inactive: true, now: t0)
        _ = t.update(idle: 0, threshold: 600, inactive: false, now: t0.addingTimeInterval(60))
        t.keepsLeaveTime = true
        XCTAssertEqual(t.update(idle: 0, threshold: 600, inactive: true, now: t0.addingTimeInterval(300)), .left(at: t0))
    }
}
