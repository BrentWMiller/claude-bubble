import simd
import XCTest
@testable import ClaudeBubbleCore

final class ColorFanTests: XCTestCase {
    func run(_ a: OrbAnimator, seconds: Double) -> OrbFrame {
        var f = a.step(dt: 0.02)
        for _ in 0..<Int(seconds / 0.02) { f = a.step(dt: 0.02) }
        return f
    }

    func testSettledOrbHasNoFan() {
        let a = OrbAnimator(state: .working, random: { 0.5 })
        XCTAssertEqual(run(a, seconds: 2).fan, -1)
    }

    func testStateChangeFansTheNewColoursIn() {
        let a = OrbAnimator(state: .working, random: { 0.5 })
        let before = run(a, seconds: 2)
        a.setState(.needs)
        let start = a.step(dt: 0.02)
        XCTAssertGreaterThanOrEqual(start.fan, 0)
        XCTAssertLessThan(start.fan, 0.1)
        // The fan sweeps from the old colours to the new state's.
        XCTAssertLessThan(simd_distance(start.fanFrom.c1, before.params.c1), 0.02)
        XCTAssertLessThan(simd_distance(start.params.c1, OrbPalette.agentsView.needs.c1), 0.02)
        XCTAssertEqual(run(a, seconds: 0.4).fan, Float(0.44 / OrbAnimator.fanDuration), accuracy: 0.05)
        XCTAssertEqual(run(a, seconds: 1).fan, -1, "done after ~1.4s")
    }

    func testPaletteChangeFansToo() {
        let a = OrbAnimator(state: .idle, random: { 0.5 })
        _ = run(a, seconds: 2)
        a.palette = .blue
        XCTAssertGreaterThanOrEqual(a.step(dt: 0.02).fan, 0)
    }

    func testChangeMidFanStartsFromWhatsShowing() {
        let a = OrbAnimator(state: .working, random: { 0.5 })
        _ = run(a, seconds: 2)
        a.setState(.needs)
        _ = run(a, seconds: 1.0)   // mostly needs by now (~70% through)
        a.setState(.error)
        let f = a.step(dt: 0.02)
        XCTAssertLessThan(f.fan, 0.1, "a fresh fan")
        XCTAssertLessThan(simd_distance(f.fanFrom.c1, OrbPalette.agentsView.needs.c1),
                          simd_distance(f.fanFrom.c1, OrbPalette.agentsView.working.c1), "starts from the mostly-needs look")
    }
}
