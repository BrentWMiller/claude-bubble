import XCTest
@testable import ClaudeBubbleCore

final class RingPopTests: XCTestCase {
    func steps(_ a: OrbAnimator, _ seconds: Double) -> OrbFrame {
        var f = a.step(dt: 1.0 / 60)
        for _ in 0..<Int(seconds * 60) { f = a.step(dt: 1.0 / 60) }
        return f
    }

    func testNoPopUntilAsked() {
        XCTAssertEqual(OrbAnimator(state: .working).step(dt: 1.0 / 60).pop, -1)
    }

    func testRingPopRunsThenEnds() {
        let a = OrbAnimator(state: .working)
        a.ringPop()
        XCTAssertEqual(a.step(dt: 1.0 / 60).pop, 1.0 / 60, accuracy: 0.001)
        XCTAssertGreaterThan(steps(a, 1).pop, 0.9)
        XCTAssertEqual(steps(a, 1).pop, -1, "over after ~1.6s")
    }

    func testRingPopDoesNotChangeTheState() {
        let a = OrbAnimator(state: .working)
        a.ringPop()
        _ = steps(a, 0.5)
        XCTAssertEqual(a.state, .working)
        XCTAssertEqual(steps(a, 0.1).completion, -1, "a ring pop is not the full celebration")
    }

    func testPullStretchesTowardThePipThenWobblesBack() {
        let a = OrbAnimator(state: .working)
        a.pull(towards: [0, -1])   // straight down (y-up)
        XCTAssertEqual(a.step(dt: 1.0 / 60).pullAngle, -.pi / 2, accuracy: 0.001)
        let stretch = (0..<18).map { _ in a.step(dt: 1.0 / 60).pull }   // up to 0.317s, just before the snap
        XCTAssertEqual(stretch.last ?? 0, 1, accuracy: 0.03, "fully stretched at the snap (0.32s)")
        XCTAssertEqual(stretch, stretch.sorted(), "stretches smoothly, never backwards")
        let after = (0..<30).map { _ in a.step(dt: 1.0 / 60).pull }
        XCTAssertLessThan(after.min() ?? 0, 0, "springs back past rest: a wobble")
        _ = steps(a, 2)
        XCTAssertEqual(a.step(dt: 1.0 / 60).pull, 0, "settled after ~2s")
    }

    func testNoPullUntilAsked() {
        XCTAssertEqual(OrbAnimator(state: .working).step(dt: 1.0 / 60).pull, 0)
    }
}
