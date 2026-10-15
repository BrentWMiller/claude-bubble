import XCTest
@testable import ClaudeBubbleCore

final class CompletionTests: XCTestCase {
    func steps(_ a: OrbAnimator, _ seconds: Double) -> [OrbFrame] {
        (0..<Int(seconds * 60)).map { _ in a.step(dt: 1.0 / 60) }
    }

    func finishedWork() -> OrbAnimator {
        let a = OrbAnimator(state: .working, random: { 0.5 })
        _ = steps(a, 1)
        a.setState(.idle)
        return a
    }

    func testWorkingToIdlePlaysTheCompletion() {
        let a = finishedWork()
        let first = a.step(dt: 1.0 / 60)
        XCTAssertEqual(first.completion, 0.5 / 60, accuracy: 0.001, "plays at half speed")
        _ = steps(a, 2.2)
        XCTAssertGreaterThan(a.step(dt: 1.0 / 60).completion, 1)
    }

    func testCompletionEndsAfterEightSeconds() {
        let a = finishedWork()
        _ = steps(a, 7.5)
        XCTAssertGreaterThan(a.step(dt: 1.0 / 60).completion, 0, "still playing at 7.5s")
        _ = steps(a, 0.6)
        XCTAssertEqual(a.step(dt: 1.0 / 60).completion, -1)
    }

    func testOtherTransitionsDontCelebrate() {
        for from in [BubbleState.needs, .error] {
            let a = OrbAnimator(state: from)
            a.setState(.idle)
            XCTAssertEqual(a.step(dt: 1.0 / 60).completion, -1, "\(from) → idle")
        }
        XCTAssertEqual(OrbAnimator(state: .idle).step(dt: 1.0 / 60).completion, -1, "startup")
    }

    func testStartingWorkAgainCancelsIt() {
        let a = finishedWork()
        _ = steps(a, 0.3)
        a.setState(.working)
        XCTAssertEqual(a.step(dt: 1.0 / 60).completion, -1)
    }

    func testColoursHoldUntilTheReleaseThenEaseToRest() {
        let a = finishedWork()
        _ = steps(a, 0.75)
        XCTAssertEqual(a.current.c1, OrbPalette.agentsView.working.c1, "still working colours before the release (0.84s)")
        _ = steps(a, 4)
        XCTAssertEqual(a.current.c1.y, OrbPalette.agentsView.idle.c1.y, accuracy: 0.02, "rest colours after")
    }

    func testGatherThenSpringyRelease() {
        let a = finishedWork()
        let frames = steps(a, 2.4)
        let base = OrbParams.target(for: .working).scale
        let atGather = frames[Int(0.74 * 60)].scale        // just before the release
        XCTAssertLessThan(atGather, base * 0.97, "inhales")
        let released = frames[Int(0.85 * 60)...].map(\.glow).max() ?? 0   // release at 0.42 / 0.5 = 0.84s
        XCTAssertGreaterThan(released, 2, "glow blooms on release")
    }
}
