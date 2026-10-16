import XCTest
@testable import ClaudeBubbleCore

final class PointerFollowTests: XCTestCase {
    let a = PointerFollow.Display(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), visible: CGRect(x: 0, y: 25, width: 2560, height: 1390))
    let b = PointerFollow.Display(frame: CGRect(x: 2560, y: 0, width: 1440, height: 900), visible: CGRect(x: 2560, y: 0, width: 1440, height: 875))
    let panelOnA = CGRect(x: 1220, y: 100, width: 120, height: 120)

    func destination(enabled: Bool = true, buttonDown: Bool = false, mouse: CGPoint, spot: CGPoint? = CGPoint(x: 0.5, y: 0.5)) -> CGPoint? {
        PointerFollow.destination(enabled: enabled, buttonDown: buttonDown, mouse: mouse, panelFrame: panelOnA, displays: [a, b], spot: spot)
    }

    func testMovesToTheSpotOnThePointersDisplay() {
        XCTAssertEqual(destination(mouse: CGPoint(x: 3000, y: 400)), CGPoint(x: 2560 + 720 - 60, y: 437.5 - 60))
    }

    func testStaysWhenThePointerIsOnTheSameDisplay() {
        XCTAssertNil(destination(mouse: CGPoint(x: 100, y: 100)))
    }

    func testDoesNothingWhenDisabled() {
        XCTAssertNil(destination(enabled: false, mouse: CGPoint(x: 3000, y: 400)))
    }

    func testNeverMovesMidDrag() {
        XCTAssertNil(destination(buttonDown: true, mouse: CGPoint(x: 3000, y: 400)))
    }

    func testFallsBackToBottomCentreWithoutASpot() {
        XCTAssertEqual(destination(mouse: CGPoint(x: 3000, y: 400), spot: nil), CGPoint(x: 2560 + 720 - 60, y: 87.5 - 60))
    }

    func testEnablingFollowRecordsTheCurrentSpot() {
        let p = BubblePreferences.defaults.withFollow(true, currentSpot: CGPoint(x: 0.9, y: 0.8))
        XCTAssertTrue(p.followPointer)
        XCTAssertEqual(p.relativeSpot, [0.9, 0.8])
    }

    func testDisablingFollowKeepsTheSpot() {
        var p = BubblePreferences.defaults
        p.followPointer = true
        p.relativeSpot = [0.2, 0.3]
        let off = p.withFollow(false, currentSpot: CGPoint(x: 0.9, y: 0.9))
        XCTAssertFalse(off.followPointer)
        XCTAssertEqual(off.relativeSpot, [0.2, 0.3])
    }

    func testStaysWhileHangingOffItsDisplaysEdge() {
        // Dragged mostly off a's left edge: the centre is off every screen, but it still belongs to a.
        let hanging = CGRect(x: -60 - 28, y: 400, width: 120, height: 120)
        XCTAssertNil(PointerFollow.destination(enabled: true, buttonDown: false, mouse: CGPoint(x: 500, y: 500),
                                               panelFrame: hanging, displays: [a, b], spot: CGPoint(x: 0.5, y: 0.5)))
    }

    func testOffEdgeSpotLandsHangingOffTheOtherDisplay() {
        // A spot past the right edge (the orb was hanging off it) keeps hanging off b's right edge.
        let spot = CGPoint(x: 1 + 20.0 / 2560, y: 0.5)
        let o = PointerFollow.destination(enabled: true, buttonDown: false, mouse: CGPoint(x: 3000, y: 400),
                                          panelFrame: panelOnA, displays: [a, b], spot: spot)
        XCTAssertEqual(try XCTUnwrap(o).x + 60, b.frame.maxX + 20 * 1440 / 2560, accuracy: 0.5)
    }
}
