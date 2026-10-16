import XCTest
@testable import ClaudeBubbleCore

final class MotionAnimatorTests: XCTestCase {
    func animator(_ state: BubbleState = .working) -> OrbAnimator { OrbAnimator(state: state, random: { 0.5 }) }

    func run(_ a: OrbAnimator, seconds: Double) -> OrbFrame {
        var f = a.step(dt: 0.02)
        for _ in 0..<Int(seconds / 0.02) { f = a.step(dt: 0.02) }
        return f
    }

    func testMotionBlendsInWhileWorking() {
        let a = animator()
        a.motion = .read
        let early = run(a, seconds: 0.1)
        XCTAssertEqual(early.workB, Motion.read.shaderMode)
        XCTAssertEqual(early.workA, Motion.generating.shaderMode)
        XCTAssertLessThan(early.workMix, 0.1)
        XCTAssertEqual(run(a, seconds: 2).workMix, 1)
    }

    func testOtherStatesUseTheWorkingWave() {
        let a = animator(.needs)
        a.motion = .bash
        let f = run(a, seconds: 3)
        XCTAssertEqual(f.workB, Motion.generating.shaderMode)
        XCTAssertEqual(f.workMix, 1)
    }

    func testTicksStackUpToThreeAndQuietInBursts() {
        let a = animator()
        _ = run(a, seconds: 0.1)
        for _ in 0..<5 { a.tick(); _ = a.step(dt: 0.05) }
        let f = a.step(dt: 0.02)
        let live = [f.tickAges.x, f.tickAges.y, f.tickAges.z].filter { $0 >= 0 }
        XCTAssertEqual(live.count, 3)
        XCTAssertEqual(f.tickAmps.x, 1 / (1 + 0.35 * 2), accuracy: 0.001, "oldest kept was the third in the burst")
        XCTAssertEqual(f.tickAmps.z, 1 / (1 + 0.35 * 4), accuracy: 0.001)
        XCTAssertEqual(run(a, seconds: 1).tickAges, SIMD3(-1, -1, -1), "gone within 0.8s")
    }

    func testTickAmplitudeFloor() {
        let a = animator()
        for _ in 0..<12 { a.tick(); _ = a.step(dt: 0.02) }
        XCTAssertEqual(a.step(dt: 0.02).tickAmps.z, 0.3, accuracy: 0.001)
    }

    func testFailAndSkillAges() {
        let a = animator()
        XCTAssertEqual(run(a, seconds: 0.1).failAge, -1)
        a.fail()
        a.skill()
        let f = run(a, seconds: 0.5)
        XCTAssertEqual(f.failAge, 0.52, accuracy: 0.03)
        XCTAssertEqual(f.skillAge, 0.52, accuracy: 0.03)
        let later = run(a, seconds: 2)
        XCTAssertEqual(later.failAge, -1)
        XCTAssertEqual(later.skillAge, -1)
    }

    func testSkillGivesAQuickSpin() {
        let plain = animator(), spun = animator()
        _ = run(plain, seconds: 0.5); _ = run(spun, seconds: 0.5)
        spun.skill()
        let p = run(plain, seconds: 1.5).phase, s = run(spun, seconds: 1.5).phase
        XCTAssertGreaterThan(s - p, 0.9, "about 1.2 × 1.4 × 2/π extra")
    }

    func testSubagentsEase() {
        let a = animator()
        a.subagents = 3
        XCTAssertLessThan(run(a, seconds: 0.1).sub, 1)
        XCTAssertEqual(run(a, seconds: 3).sub, 3, accuracy: 0.01)
    }

    func testBashSettlesWithElapsedTime() {
        let a = animator()
        a.motion = .bash
        a.motionElapsed = 30
        XCTAssertEqual(run(a, seconds: 5).settle, Float(1 - exp(-30.0 / 6)), accuracy: 0.01)
        a.motionElapsed = 0   // a new command: back to a boil at once
        XCTAssertLessThan(a.step(dt: 0.02).settle, 0.05)
    }
}
