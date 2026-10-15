import XCTest
@testable import ClaudeBubbleCore

final class PaletteTests: XCTestCase {
    func assertColors(_ c: StateColors, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>, _ c3: SIMD3<Float>, _ halo: SIMD3<Float>,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.c1, c1, file: file, line: line)
        XCTAssertEqual(c.c2, c2, file: file, line: line)
        XCTAssertEqual(c.c3, c3, file: file, line: line)
        XCTAssertEqual(c.halo, halo, file: file, line: line)
    }

    func testAgentsViewIsTodaysColors() {
        let p = OrbPalette.agentsView
        assertColors(p.idle, [0.42, 0.88, 0.56], [0.22, 0.62, 0.4], [0.72, 0.96, 0.78], [0.06, 0.3, 0.14])
        assertColors(p.working, [1, 0.46, 0.2], [0.56, 0.3, 1], [1, 0.45, 0.72], [0.3, 0.14, 0.75])
        assertColors(p.needs, [1, 0.86, 0.24], [1, 0.66, 0.12], [1, 0.95, 0.62], [0.55, 0.4, 0.04])
        assertColors(p.error, [1, 0.2, 0.22], [0.72, 0.08, 0.2], [1, 0.55, 0.45], [0.5, 0.03, 0.06])
        XCTAssertEqual(p.working.swatch, p.working.c2)
        XCTAssertEqual(p.idle.swatch, p.idle.c1)
    }

    func testOriginalDesignIsTheJSClaudePalette() {
        let p = OrbPalette.originalDesign
        assertColors(p.idle, [0.62, 0.66, 0.82], [0.4, 0.44, 0.62], [0.8, 0.82, 0.95], [0.16, 0.18, 0.34])
        assertColors(p.needs, [1, 0.72, 0.22], [1, 0.38, 0.24], [1, 0.86, 0.55], [0.6, 0.24, 0.08])
        XCTAssertEqual(p.working, OrbPalette.agentsView.working)
        XCTAssertEqual(p.error, OrbPalette.agentsView.error)
    }

    func testBlueIsTheJSBluePalette() {
        let p = OrbPalette.blue
        assertColors(p.idle, [0.55, 0.6, 1], [0.35, 0.38, 0.85], [0.7, 0.8, 1], [0.08, 0.1, 0.45])
        assertColors(p.working, [1, 0.3, 0.9], [0.3, 0.78, 1], [1, 0.72, 0.6], [0.12, 0.1, 0.95])
        XCTAssertEqual(p.needs, OrbPalette.originalDesign.needs)
    }

    func testPresetsByName() {
        XCTAssertEqual(OrbPalette.presets.map(\.name), ["Agents view", "Original design", "Blue"])
        XCTAssertEqual(OrbPalette.preset(named: "Blue"), .blue)
        XCTAssertNil(OrbPalette.preset(named: "Nope"))
    }

    func testTargetUsesThePalette() {
        let params = OrbParams.target(for: .idle, palette: .blue)
        XCTAssertEqual(params.c1, OrbPalette.blue.idle.c1)
        XCTAssertEqual(params.scale, OrbParams.target(for: .idle).scale)
        XCTAssertEqual(OrbParams.target(for: .needs).c1, OrbPalette.agentsView.needs.c1)
    }

    func testSubscriptSetsOneState() {
        var p = OrbPalette.agentsView
        p[.error] = OrbPalette.blue.idle
        XCTAssertEqual(p.error, OrbPalette.blue.idle)
        XCTAssertEqual(p.idle, OrbPalette.agentsView.idle)
    }

    func testDerivationShape() {
        let base: SIMD3<Float> = [0.2, 0.6, 0.9]
        let c = PaletteDerivation.colors(from: base)
        XCTAssertEqual(c.c1, base)
        XCTAssertEqual(c.swatch, base)
        XCTAssertGreaterThan(c.c3.sum(), base.sum(), "c3 lighter")
        XCTAssertLessThan(c.halo.sum(), base.sum(), "halo darker")
        XCTAssertEqual(c.halo, base * 0.45)
        XCTAssertNotEqual(c.c2, base)
        XCTAssertEqual(PaletteDerivation.hue(of: c.c2), (PaletteDerivation.hue(of: base) - 25 + 360).truncatingRemainder(dividingBy: 360), accuracy: 0.5)
    }

    func testDerivationStaysInRange() {
        for base: SIMD3<Float> in [[0, 0, 0], [1, 1, 1], [1, 0, 0], [0, 0, 1], [0.05, 0.05, 0.05]] {
            let c = PaletteDerivation.colors(from: base)
            for v in [c.c1, c.c2, c.c3, c.halo, c.swatch] {
                XCTAssertTrue((0...1).contains(v.min()) && (0...1).contains(v.max()), "\(base) → \(v)")
            }
        }
    }

    func testPaletteRoundTripsThroughJSON() throws {
        var p = OrbPalette.originalDesign
        p[.working] = PaletteDerivation.colors(from: [0.1, 0.9, 0.3])
        let back = try JSONDecoder().decode(OrbPalette.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    func testAnimatorEasesToANewPalette() {
        let a = OrbAnimator(state: .working)
        a.palette = .blue
        _ = a.step(dt: 1.0 / 60)
        XCTAssertNotEqual(a.current.c1, OrbPalette.agentsView.working.c1)
        XCTAssertNotEqual(a.current.c1, OrbPalette.blue.working.c1)
        for _ in 0..<120 { _ = a.step(dt: 1.0 / 60) }
        XCTAssertEqual(a.current.c1.x, OrbPalette.blue.working.c1.x, accuracy: 0.01)
    }
}
