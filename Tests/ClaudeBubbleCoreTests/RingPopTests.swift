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

    func testEmitDripsTowardThePipThenHeals() {
        let a = OrbAnimator(state: .working)
        a.emit(to: [0.3, -1.25])   // the pip's slot, in orb radii (y-up)
        let f = a.step(dt: 1.0 / 60)
        XCTAssertEqual(f.emit, 1.0 / 60, accuracy: 0.001)
        XCTAssertEqual(f.emitTarget, [0.3, -1.25], "the drip aims at the slot itself, not just a direction")
        XCTAssertGreaterThan(steps(a, 1).emit, 1, "still healing at 1s")
        XCTAssertEqual(steps(a, 0.3).emit, -1, "done by ~1.25s")
    }

    func testNoEmitUntilAsked() {
        XCTAssertEqual(OrbAnimator(state: .working).step(dt: 1.0 / 60).emit, -1)
    }
}
