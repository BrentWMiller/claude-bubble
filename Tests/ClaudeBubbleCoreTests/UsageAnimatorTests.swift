import simd
import XCTest
@testable import ClaudeBubbleCore

final class UsageAnimatorTests: XCTestCase {
    func pair(_ state: BubbleState) -> (OrbAnimator, OrbAnimator) {
        (OrbAnimator(state: state, random: { 0.5 }), OrbAnimator(state: state, random: { 0.5 }))
    }

    func run(_ a: OrbAnimator, seconds: Double) -> OrbFrame {
        var f = a.step(dt: 0.02)
        for _ in 0..<Int(seconds / 0.02) { f = a.step(dt: 0.02) }
        return f
    }

    func testLowUsageQuietsTheOrb() {
        let (plain, low) = pair(.working)
        low.usageLeft = 6
        let p = run(plain, seconds: 4), l = run(low, seconds: 4)
        XCTAssertEqual(l.scale / p.scale, 0.88, accuracy: 0.005)
        XCTAssertEqual(l.glow / p.glow, 0.6, accuracy: 0.005)
        // Swirl speed: phase advance over the next second.
        let p0 = p.phase, l0 = l.phase
        let p1 = run(plain, seconds: 1).phase, l1 = run(low, seconds: 1).phase
        XCTAssertEqual((l1 - l0) / (p1 - p0), 0.4, accuracy: 0.01)
    }

    func testLowUsageEasesInAndBackOut() {
        let (plain, low) = pair(.working)
        low.usageLeft = 6
        let early = run(low, seconds: 0.2).scale / run(plain, seconds: 0.2).scale
        XCTAssertGreaterThan(early, 0.93, "eases rather than snapping to 0.88")
        _ = run(low, seconds: 4); _ = run(plain, seconds: 4)
        low.usageLeft = 100
        XCTAssertEqual(run(low, seconds: 4).scale / run(plain, seconds: 4).scale, 1, accuracy: 0.005)
    }

    func testTintEasesTowardNeedsColours() {
        let (plain, warm) = pair(.working)
        warm.usageLeft = 25
        let early = run(warm, seconds: 0.1)
        let needs = OrbPalette.agentsView.needs
        XCTAssertGreaterThan(simd_distance(early.params.halo, needs.halo), 0.05, "no jump")
        let settled = run(warm, seconds: 4)
        XCTAssertLessThan(simd_distance(settled.params.halo, needs.halo), 0.01)
        XCTAssertLessThan(simd_distance(settled.params.c2, run(plain, seconds: 4.1).params.c2), 0.01)
        XCTAssertEqual(settled.scale / run(plain, seconds: 0).scale, 1, accuracy: 0.01, "25% is not low-usage mode")
    }

    func testNoUsageNoChange() {
        let (plain, off) = pair(.idle)
        off.usageLeft = nil
        let a = run(plain, seconds: 2), b = run(off, seconds: 2)
        XCTAssertEqual(a.params, b.params)
        XCTAssertEqual(a.scale, b.scale)
    }

    func testTintHandsOffSmoothlyWhenTheStateChanges() {
        let a = OrbAnimator(state: .working, random: { 0.5 })
        a.usageLeft = 25
        let tinted = run(a, seconds: 4).params.halo
        a.setState(.needs)
        let next = a.step(dt: 0.02).params.halo
        // A plain working → needs change moves this far in one frame; the tinted orb must not move more
        // (without easing the tint out, it snaps back to the working halo first: ~0.4 away).
        let plain = OrbAnimator(state: .working, random: { 0.5 })
        let before = run(plain, seconds: 4).params.halo
        plain.setState(.needs)
        let ease = simd_distance(before, plain.step(dt: 0.02).params.halo)
        XCTAssertLessThanOrEqual(simd_distance(tinted, next), ease * 1.5, "no jump back to the working colours")
    }
}
