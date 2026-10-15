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
}
