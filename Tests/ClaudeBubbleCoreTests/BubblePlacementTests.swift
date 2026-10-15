import XCTest
@testable import ClaudeBubbleCore

final class BubblePlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)

    func testDefaultIsBottomCenterAboveDock() {
        let o = BubblePlacement.origin(saved: nil, size: 120, screenFrames: [screen], mainVisibleFrame: visible)
        XCTAssertEqual(o, CGPoint(x: 660, y: 126))
    }

    func testSavedOriginOnScreenIsKept() {
        let o = BubblePlacement.origin(saved: CGPoint(x: 100, y: 500), size: 120, screenFrames: [screen], mainVisibleFrame: visible)
        XCTAssertEqual(o, CGPoint(x: 100, y: 500))
    }

    func testSavedOriginOffScreenFallsBack() {
        let o = BubblePlacement.origin(saved: CGPoint(x: 3000, y: 500), size: 120, screenFrames: [screen], mainVisibleFrame: visible)
        XCTAssertEqual(o, CGPoint(x: 660, y: 126))
    }

    func testOnlyTheOrbItselfCatchesTheMouse() {
        let panel = CGRect(x: 100, y: 100, width: 120, height: 120)
        XCTAssertTrue(BubblePlacement.isOverOrb(CGPoint(x: 160, y: 160), panelFrame: panel))
        XCTAssertTrue(BubblePlacement.isOverOrb(CGPoint(x: 195, y: 160), panelFrame: panel))
        XCTAssertFalse(BubblePlacement.isOverOrb(CGPoint(x: 200, y: 160), panelFrame: panel))
        XCTAssertFalse(BubblePlacement.isOverOrb(CGPoint(x: 105, y: 105), panelFrame: panel))
    }
}
