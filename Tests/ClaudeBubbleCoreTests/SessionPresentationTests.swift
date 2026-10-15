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

    // HoverTracker (open after 0.6s resting on the orb, close 0.35s after leaving both)
    let o = HoverTracker.openDelay, c = HoverTracker.closeDelay

    func testDelays() {
        XCTAssertEqual(HoverTracker.openDelay, 0.6)
        XCTAssertEqual(HoverTracker.closeDelay, 0.35)
    }

    func testOpensOnlyAfterTheDelay() {
        var h = HoverTracker()
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: o - 0.01))
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.01))
    }

    func testPassingOverDoesNotOpen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: false, overList: false, hasContent: true, now: 0.2)
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.05))
    }

    func testMovingIntoTheListKeepsItOpen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.1)
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: o + 0.5))
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: o + 5))
    }

    func testClosesAfterLeavingBoth() {
        var h = HoverTracker()
        let open = o + 0.1
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: open)
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: open + 0.1))
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: open + 0.2))   // came back in time
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: open + 0.3))
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: open + 0.3 + c - 0.01))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: open + 0.3 + c + 0.01))
    }

    func testNoContentNeverOpens() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: false, now: 0)
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: false, now: o + 1))
    }

    func testLosingContentCloses() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.1))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: false, now: o + 0.2))
    }

    func testDismissFromTheListDoesNotReopen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.05)
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: o + 0.1))
        h.dismiss()
        // The hidden list no longer reports overList; the close delay must not resurrect it.
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: o + 0.15))
        XCTAssertFalse(h.update(overOrb: false, overList: true, hasContent: true, now: o + 0.2))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: o + 1))
    }

    func testDismissWhileOnTheOrbWaitsForThePointerToLeave() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.1))
        h.dismiss()
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: o + 0.2))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: o + 1.2))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: o + 1.3))
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: o + 1.4)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 2 * o + 1.45))
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

    // Status tones in the list, like the agents view's groups
    func testStatusTones() {
        let now = Date()
        func tone(_ state: BubbleState, detail: String = "", review: Bool = false) -> StatusTone {
            Session(id: "x", state: state, updatedAt: now, detail: detail, reviewReady: review).tone
        }
        XCTAssertEqual(tone(.working, detail: "Running tests"), .working)
        XCTAssertEqual(tone(.needs, detail: "Approve Edit auth.ts?"), .attention)
        XCTAssertEqual(tone(.idle, detail: "Completed", review: true), .attention, "ready for review is orange too")
        XCTAssertEqual(tone(.error, detail: "Build failed"), .error)
        XCTAssertEqual(tone(.idle, detail: "Completed"), .completed)
        XCTAssertEqual(tone(.idle, detail: "Idle"), .idle, "went quiet without finishing")
    }
}
