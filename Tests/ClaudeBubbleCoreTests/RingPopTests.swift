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

    func testQuietStateChangeNeverCelebrates() {
        let a = OrbAnimator(state: .working)
        a.setState(.idle, quiet: true)
        XCTAssertEqual(a.step(dt: 1.0 / 60).completion, -1)
        a.setState(.working, quiet: true)
        a.setState(.idle)
        XCTAssertGreaterThan(a.step(dt: 1.0 / 60).completion, 0, "a normal change still celebrates")
    }
}
