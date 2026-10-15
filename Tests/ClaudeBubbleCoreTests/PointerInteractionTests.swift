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

    func testDirectionPointsAtTheCursor() {
        let d = PointerProximity.direction(mouse: CGPoint(x: 100, y: 150), centre: CGPoint(x: 100, y: 100))
        XCTAssertEqual(d.x, 0, accuracy: 0.0001)
        XCTAssertEqual(d.y, 1, accuracy: 0.0001)
        XCTAssertEqual(PointerProximity.direction(mouse: CGPoint(x: 100, y: 100), centre: CGPoint(x: 100, y: 100)), .zero)
    }

    // Animator
    func testAttentionModeEasesInAndSwellsTheGlow() {
        let a = OrbAnimator(state: .working)
        a.interaction = .attention
        let base = run(a, seconds: 0.5).glow
        a.setPointer(direction: [0, 1], closeness: 1)
        let f = run(a, seconds: 1)
        XCTAssertEqual(f.attention, 1, accuracy: 0.01)
        XCTAssertEqual(f.magnet, 0)
        XCTAssertEqual(f.glow, base * 1.2, accuracy: 0.02)
        XCTAssertEqual(f.pointerAngle, .pi / 2, accuracy: 0.01)
    }

    func testMagneticModeDrivesTheMagnetOnly() {
        let a = OrbAnimator(state: .working)
        a.interaction = .magnetic
        a.setPointer(direction: [1, 0], closeness: 1)
        let f = run(a, seconds: 1)
        XCTAssertEqual(f.magnet, 1, accuracy: 0.01)
        XCTAssertEqual(f.attention, 0)
    }

    func testOffModeIgnoresThePointer() {
        let a = OrbAnimator(state: .working)
        a.interaction = .off
        a.setPointer(direction: [1, 0], closeness: 1)
        let f = run(a, seconds: 1)
        XCTAssertEqual(f.attention, 0)
        XCTAssertEqual(f.magnet, 0)
    }

    func testLeavingSettlesBackToNormal() {
        let a = OrbAnimator(state: .working)
        a.setPointer(direction: [1, 0], closeness: 1)
        _ = run(a, seconds: 1)
        a.setPointer(direction: [1, 0], closeness: 0)
        XCTAssertEqual(run(a, seconds: 1.5).attention, 0, accuracy: 0.01)
    }

    func testFirstStepDoesNotJump() {
        let a = OrbAnimator(state: .working)
        a.setPointer(direction: [1, 0], closeness: 1)
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
