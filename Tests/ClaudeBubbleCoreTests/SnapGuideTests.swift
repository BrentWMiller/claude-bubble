import XCTest
@testable import ClaudeBubbleCore

final class SnapGuideTests: XCTestCase {
    func testSnapsWithinTwelvePoints() {
        var snap = SnapGuide()
        XCTAssertEqual(snap.apply(470, centre: 500), 470)
        XCTAssertFalse(snap.snapped)
        XCTAssertEqual(snap.apply(489, centre: 500), 500)
        XCTAssertTrue(snap.snapped)
    }

    func testHoldsUntilTwentyFourPointsAway() {
        var snap = SnapGuide()
        _ = snap.apply(505, centre: 500)
        XCTAssertEqual(snap.apply(520, centre: 500), 500, "sticky past the snap-in distance")
        XCTAssertEqual(snap.apply(476, centre: 500), 500, "either side")
        XCTAssertEqual(snap.apply(525, centre: 500), 525, "breaks free past 24pt")
        XCTAssertFalse(snap.snapped)
        XCTAssertEqual(snap.apply(515, centre: 500), 515, "and needs to come back within 12pt to snap again")
    }

    func testReset() {
        var snap = SnapGuide()
        _ = snap.apply(500, centre: 500)
        snap.reset()
        XCTAssertFalse(snap.snapped)
    }

    func testLinesFrameTheCentredThing() {
        let lines = SnapGuide.lines(centre: 500, extent: 120)
        XCTAssertEqual(lines.0, 440)
        XCTAssertEqual(lines.1, 560)
    }

    // The island's drag: snapping the pointer to the edge's centre puts the island exactly in the middle.
    func testCentredPointerCentresTheIsland() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let target = IslandLayout.nearest(CGPoint(x: visible.midX, y: visible.maxY - 5), visible: visible)
        XCTAssertEqual(target.dock, .top)
        XCTAssertEqual(target.along, 0.5)
        XCTAssertEqual(IslandLayout.windowFrame(dock: .top, visible: visible, along: target.along).midX, visible.midX)
    }
}
