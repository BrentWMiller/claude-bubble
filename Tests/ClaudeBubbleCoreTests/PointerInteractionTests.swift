import XCTest
@testable import ClaudeBubbleCore

final class PointerInteractionTests: XCTestCase {
    func run(_ a: OrbAnimator, seconds: Double) -> OrbFrame {
        var f = a.step(dt: 1.0 / 60)
        for _ in 0..<Int(seconds * 60) { f = a.step(dt: 1.0 / 60) }
        return f
    }

    // Proximity
    func testClosenessIsFullOverTheOrbAndNoneBeyondReach() {
        let centre = CGPoint(x: 100, y: 100)
        XCTAssertEqual(PointerProximity.closeness(mouse: CGPoint(x: 110, y: 100), centre: centre, radius: 36), 1)
        XCTAssertEqual(PointerProximity.closeness(mouse: CGPoint(x: 100 + 36 * 2.5 + 1, y: 100), centre: centre, radius: 36), 0)
        XCTAssertEqual(PointerProximity.closeness(mouse: CGPoint(x: 100 + 36 * 1.75, y: 100), centre: centre, radius: 36), 0.5, accuracy: 0.01)
    }

    func testOffsetShrinksTowardTheCentre() {
        let centre = CGPoint(x: 100, y: 100)
        let up = PointerProximity.offset(mouse: CGPoint(x: 100, y: 150), centre: centre, radius: 36)
        XCTAssertEqual(up.x, 0, accuracy: 0.0001)
        XCTAssertEqual(up.y, 1, accuracy: 0.0001, "capped at the orb's edge")
        let half = PointerProximity.offset(mouse: CGPoint(x: 118, y: 100), centre: centre, radius: 36)
        XCTAssertEqual(half.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PointerProximity.offset(mouse: centre, centre: centre, radius: 36), .zero)
    }

    // Animator
    func testAttentionModeEasesInAndSwellsTheGlow() {
        let a = OrbAnimator(state: .working)
        a.interaction = .attention
        let base = run(a, seconds: 0.5).glow
        a.setPointer(offset: [0, 1], closeness: 1)
        let f = run(a, seconds: 2)
        XCTAssertEqual(f.attention, 1, accuracy: 0.01)
        XCTAssertEqual(f.magnet, 0)
        XCTAssertEqual(f.glow, base * 1.2, accuracy: 0.02)
        XCTAssertEqual(f.pointerAngle, .pi / 2, accuracy: 0.01)
    }

    func testMagneticModeDrivesTheMagnetOnly() {
        let a = OrbAnimator(state: .working)
        a.interaction = .magnetic
        a.setPointer(offset: [1, 0], closeness: 1)
        let f = run(a, seconds: 2)
        XCTAssertEqual(f.magnet, 1, accuracy: 0.01)
        XCTAssertEqual(f.attention, 0)
    }

    func testOffModeIgnoresThePointer() {
        let a = OrbAnimator(state: .working)
        a.interaction = .off
        a.setPointer(offset: [1, 0], closeness: 1)
        let f = run(a, seconds: 1)
        XCTAssertEqual(f.attention, 0)
        XCTAssertEqual(f.magnet, 0)
    }

    func testLeavingSettlesBackToNormal() {
        let a = OrbAnimator(state: .working)
        a.setPointer(offset: [1, 0], closeness: 1)
        _ = run(a, seconds: 2)
        a.setPointer(offset: [1, 0], closeness: 0)
        XCTAssertEqual(run(a, seconds: 2).attention, 0, accuracy: 0.01)
    }

    func testCrossingTheMiddleFadesThroughInsteadOfFlipping() {
        let a = OrbAnimator(state: .working)
        a.setPointer(offset: [1, 0], closeness: 1)
        var last = run(a, seconds: 2)
        a.setPointer(offset: [-1, 0], closeness: 1)   // cursor jumps to the opposite side
        var weakest: Float = 1
        // What's visible is the lean: strength × direction. It must move continuously, with no frame-to-frame jump.
        // Even when the cursor teleports across, the reaction starts from rest and never moves faster than a glide.
        func lean(_ f: OrbFrame) -> SIMD2<Float> { SIMD2(cosf(f.pointerAngle), sinf(f.pointerAngle)) * f.attention }
        for frame in 0..<120 {
            let f = a.step(dt: 1.0 / 60)
            let jump = lean(f) - lean(last)
            let size = (jump * jump).sum().squareRoot()
            // The old exponential easing moved 0.126 on the first frame; the spring must start ~10× gentler.
            if frame == 0 { XCTAssertLessThan(size, 0.02, "starts from rest, no jolt") }
            XCTAssertLessThan(size, 0.07, "no visible snap between frames")
            weakest = min(weakest, f.attention)
            last = f
        }
        XCTAssertLessThan(weakest, 0.2, "the effect fades out while crossing the centre")
    }

    func testCursorOverTheCentreStillSwellsTheGlow() {
        let a = OrbAnimator(state: .working)
        a.setPointer(offset: .zero, closeness: 1)
        let f = run(a, seconds: 2)
        XCTAssertEqual(f.attention, 0, accuracy: 0.01)
        XCTAssertEqual(f.glow, 1.2, accuracy: 0.02)
    }

    func testEasingIsGentle() {
        let a = OrbAnimator(state: .working)
        a.setPointer(offset: [1, 0], closeness: 1)
        XCTAssertLessThan(run(a, seconds: 0.1).attention, 0.5, "takes a beat to respond")
    }

    func testFirstStepDoesNotJump() {
        let a = OrbAnimator(state: .working)
        a.setPointer(offset: [1, 0], closeness: 1)
        XCTAssertLessThan(a.step(dt: 1.0 / 60).attention, 0.5)
    }

    // Preferences
    func testInteractionDefaultsToAttentionAndRoundTrips() {
        XCTAssertEqual(BubblePreferences.defaults.interaction, .attention)
        var p = BubblePreferences.defaults
        p.interaction = .magnetic
        let back = try? JSONDecoder().decode(BubblePreferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back?.interaction, .magnetic)
    }

    func testOlderSavedSettingsKeepTheirValues() throws {
        // A blob saved before `interaction` existed must not reset everything.
        var old = BubblePreferences.defaults
        old.diameter = 110
        old.followPointer = true
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "interaction")
        json.removeValue(forKey: "opacity")
        let p = try JSONDecoder().decode(BubblePreferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(p.diameter, 110)
        XCTAssertTrue(p.followPointer)
        XCTAssertEqual(p.interaction, .attention)
        XCTAssertEqual(p.opacity, 1)
    }
}
