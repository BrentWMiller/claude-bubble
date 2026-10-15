import XCTest
@testable import ClaudeBubbleCore

final class OrbAnimatorTests: XCTestCase {
    func run(_ a: OrbAnimator, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { _ = a.step(dt: 1.0 / 60) }
    }

    func testStartsAtTargetForInitialState() {
        XCTAssertEqual(OrbAnimator(state: .working).current, .target(for: .working))
    }

    func testEasesTowardNewState() {
        let a = OrbAnimator(state: .idle)
        a.setState(.working)
        run(a, seconds: 2)
        XCTAssertEqual(a.current.scale, 1, accuracy: 0.01)
        XCTAssertEqual(a.current.halo.z, 0.75, accuracy: 0.01)
    }

    func testNeedsBouncesThenSettles() {
        let a = OrbAnimator(state: .working)
        a.setState(.needs)
        XCTAssertEqual(a.bounce, -0.28)
        run(a, seconds: 3)
        XCTAssertEqual(a.bounce, 0, accuracy: 0.01)
    }

    func testErrorShakesOnEntryThenSettles() {
        let a = OrbAnimator(state: .working)
        a.setState(.error)
        XCTAssertEqual(a.shake, 1)
        run(a, seconds: 2)
        XCTAssertLessThan(a.shake, 0.01)
        XCTAssertEqual(a.step(dt: 1.0 / 60).shakeX, 0)
    }

    func testStartingInErrorDoesNotShake() {
        XCTAssertEqual(OrbAnimator(state: .error).shake, 0)
    }

    func testLargeFrameGapIsClamped() {
        let a = OrbAnimator(state: .idle)
        a.setState(.working)
        _ = a.step(dt: 10)
        XCTAssertLessThan(a.current.scale, 0.9)
    }

    func testErrorFlickerUsesInjectedRandom() {
        let a = OrbAnimator(state: .error, random: { 0 })
        let f = a.step(dt: 1.0 / 60)
        XCTAssertEqual(f.ring, OrbParams.target(for: .error).ring * 0.35, accuracy: 0.001)
    }

    func testSphereHasUnitPoints() {
        let pts = OrbGeometry.fibonacciSphere()
        XCTAssertEqual(pts.count, OrbGeometry.pointCount * 3)
        for i in stride(from: 0, to: pts.count, by: 3) {
            let len = (pts[i] * pts[i] + pts[i + 1] * pts[i + 1] + pts[i + 2] * pts[i + 2]).squareRoot()
            XCTAssertEqual(len, 1, accuracy: 0.0001)
        }
    }

    func testAppearGrowsFromNothingOvershootsAndSettles() {
        let a = OrbAnimator(state: .working)
        a.appear()
        XCTAssertLessThan(a.step(dt: 1.0 / 60).scale, 0.2)
        var peak: Float = 0
        for _ in 0..<36 { _ = a.step(dt: 1.0 / 60); peak = max(peak, a.presence) }
        XCTAssertGreaterThan(peak, 1.02, "springs past full size")
        run(a, seconds: 2)
        XCTAssertEqual(a.presence, 1, accuracy: 0.01)
        XCTAssertEqual(a.step(dt: 1.0 / 60).glow, 1, accuracy: 0.02, "flash has faded")
    }

    func testVanishShrinksToNothingQuickly() {
        let a = OrbAnimator(state: .working)
        a.vanish()
        run(a, seconds: 0.2)
        XCTAssertTrue(a.isVanished)
        XCTAssertEqual(a.step(dt: 1.0 / 60).scale, 0)
    }

    func testAppearAfterAHalfFinishedVanishStillArrives() {
        let a = OrbAnimator(state: .idle)
        a.vanish()
        run(a, seconds: 0.05)
        a.appear()
        XCTAssertFalse(a.isVanished)
        run(a, seconds: 2)
        XCTAssertEqual(a.presence, 1, accuracy: 0.01)
    }

    func testStartsFullyPresent() {
        XCTAssertEqual(OrbAnimator(state: .idle).presence, 1)
    }
}
