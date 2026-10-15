import XCTest
@testable import ClaudeBubbleCore

final class SessionPresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func sessions(_ states: [BubbleState]) -> [Session] {
        states.enumerated().map { Session(id: "\($0.offset)", state: $0.element, updatedAt: now) }
    }

    // ElapsedFormat
    func testElapsedFormats() {
        XCTAssertEqual(ElapsedFormat.string(-5), "0:00")
        XCTAssertEqual(ElapsedFormat.string(42), "0:42")
        XCTAssertEqual(ElapsedFormat.string(190), "3:10")
        XCTAssertEqual(ElapsedFormat.string(599), "9:59")
        XCTAssertEqual(ElapsedFormat.string(600), "10m")
        XCTAssertEqual(ElapsedFormat.string(22 * 60 + 30), "22m")
        XCTAssertEqual(ElapsedFormat.string(3600), "1h")
        XCTAssertEqual(ElapsedFormat.string(3 * 3600 + 59 * 60), "3h")
        XCTAssertEqual(ElapsedFormat.string(86400 * 2 + 5), "2d")
    }

    // HoverTracker
    func testOpensOnlyAfterTheDelay() {
        var h = HoverTracker()
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0.29))
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.31))
    }

    func testPassingOverDoesNotOpen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: false, overList: false, hasContent: true, now: 0.1)
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0.35))
    }

    func testMovingIntoTheListKeepsItOpen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0.4)
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: 1.0))
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: 5.0))
    }

    func testClosesAfterLeavingBoth() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0.4)
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: 0.5))
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.6))   // came back in time
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: 0.7))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: 0.96))
    }

    func testNoContentNeverOpens() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: false, now: 0)
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: false, now: 1))
    }

    func testLosingContentCloses() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.4))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: false, now: 0.5))
    }

    func testDismissFromTheListDoesNotReopen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0.35)
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: 0.4))
        h.dismiss()
        // The hidden list no longer reports overList; the close delay must not resurrect it.
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: 0.45))
        XCTAssertFalse(h.update(overOrb: false, overList: true, hasContent: true, now: 0.5))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: 1.0))
    }

    func testDismissWhileOnTheOrbWaitsForThePointerToLeave() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.4))
        h.dismiss()
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0.5))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 1.5))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: 1.6))
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 1.7)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 2.05))
    }

    // SessionListPlacement
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    let size = CGSize(width: 290, height: 200)

    func testOrbRectIsTheCentralSixtyPercent() {
        XCTAssertEqual(SessionListPlacement.orbRect(panelFrame: CGRect(x: 100, y: 100, width: 120, height: 120)),
                       CGRect(x: 124, y: 124, width: 72, height: 72))
    }

    func testBelowAndCentredWhenThereIsRoom() {
        let orb = CGRect(x: 684, y: 600, width: 72, height: 72)
        XCTAssertEqual(SessionListPlacement.frame(listSize: size, orbRect: orb, visibleFrame: visible),
                       CGRect(x: 575, y: 392, width: 290, height: 200))
    }

    func testFlipsAboveWhenNoRoomBelow() {
        let orb = CGRect(x: 684, y: 150, width: 72, height: 72)
        XCTAssertEqual(SessionListPlacement.frame(listSize: size, orbRect: orb, visibleFrame: visible).minY, 230)
    }

    func testClampsToTheRightEdge() {
        let orb = CGRect(x: 1400, y: 600, width: 72, height: 72)
        XCTAssertEqual(SessionListPlacement.frame(listSize: size, orbRect: orb, visibleFrame: visible).maxX, 1432)
    }
}
