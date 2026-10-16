import XCTest
@testable import ClaudeBubbleCore

final class EdgesTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let r: CGFloat = 46

    /// Slot centres in screen space (y-up) for an arc turned to `around` (view degrees, y-down).
    func slots(_ centre: CGPoint, _ n: Int, around: Double) -> [CGPoint] {
        (0..<n).map { i in
            let p = PipArc.position(slot: i, slots: n, centre: .zero, radius: r, around: around)
            return CGPoint(x: centre.x + p.x, y: centre.y - p.y)
        }
    }

    func allInside(_ pts: [CGPoint]) -> Bool { pts.allSatisfy { screen.insetBy(dx: 6, dy: 6).contains($0) } }

    // Pip arc

    func testOpenSpaceHangsStraightDown() {
        XCTAssertEqual(PipArc.around(centre: CGPoint(x: 500, y: 400), radius: r, slots: 5, visible: screen), 90)
    }

    func testDefaultAroundMatchesTheOldArc() {
        let old = PipArc.position(slot: 1, slots: 3, centre: CGPoint(x: 60, y: 60), radius: 46)
        let new = PipArc.position(slot: 1, slots: 3, centre: CGPoint(x: 60, y: 60), radius: 46, around: 90)
        XCTAssertEqual(old, new)
    }

    func testHalfOffTheRightTurnsLeft() {
        let c = CGPoint(x: 1000, y: 400)
        let a = PipArc.around(centre: c, radius: r, slots: 5, visible: screen)
        XCTAssertTrue(allInside(slots(c, 5, around: a)))
        XCTAssertTrue(slots(c, 5, around: a).allSatisfy { $0.x < c.x })
    }

    func testOffTheBottomGoesUp() {
        let c = CGPoint(x: 500, y: 0)
        let a = PipArc.around(centre: c, radius: r, slots: 5, visible: screen)
        XCTAssertTrue(allInside(slots(c, 5, around: a)))
        XCTAssertTrue(slots(c, 5, around: a).allSatisfy { $0.y > c.y })
    }

    func testCornerPointsInward() {
        let c = CGPoint(x: 1000, y: 0)
        let a = PipArc.around(centre: c, radius: r, slots: 7, visible: screen)
        let pts = slots(c, 7, around: a)
        XCTAssertTrue(allInside(pts))
        XCTAssertTrue(pts.allSatisfy { $0.x < c.x && $0.y > c.y })
    }

    func testNearButClearStaysDown() {
        // Close to the bottom, but the arc still fits below.
        XCTAssertEqual(PipArc.around(centre: CGPoint(x: 500, y: 70), radius: r, slots: 5, visible: screen), 90)
    }

    func testHitTestFollowsTheRotation() {
        let f = PipsFrame(pips: [PipFrame(id: "a", state: .working, slot: 0, rank: 0, atCenter: false, pulling: false,
                                         snapping: false, flaring: false, hopping: false, shake: 0),
                                 PipFrame(id: "b", state: .working, slot: 1, rank: 1, atCenter: false, pulling: false,
                                         snapping: false, flaring: false, hopping: false, shake: 0)],
                          slots: 2, overflow: 0, merged: false, visible: true)
        let centre = CGPoint(x: 60, y: 60)
        let p = PipArc.position(slot: 1, slots: 2, centre: centre, radius: 46, around: 180)
        XCTAssertEqual(PipArc.hit(p, frame: f, centre: centre, radius: 46, around: 180), "b")
        XCTAssertNil(PipArc.hit(p, frame: f, centre: centre, radius: 46, around: 90))
    }

    // Edge light

    func testNoLightInOpenSpace() {
        XCTAssertEqual(EdgeLight.strips(orbCentre: CGPoint(x: 500, y: 400), orbRadius: 30, screen: screen), [])
    }

    func testOneEdgeNearby() {
        let strips = EdgeLight.strips(orbCentre: CGPoint(x: 990, y: 300), orbRadius: 30, screen: screen)
        XCTAssertEqual(strips.map(\.edge), [.right])
        XCTAssertEqual(strips[0].strength, 1, accuracy: 0.001, "touching")
        XCTAssertEqual(strips[0].centre, 300)
        XCTAssertEqual(strips[0].reach, 800 / 3 * 2, accuracy: 0.01)
    }

    func testFadesWithDistance() {
        let near = EdgeLight.strips(orbCentre: CGPoint(x: 500, y: 60), orbRadius: 30, screen: screen)
        let far = EdgeLight.strips(orbCentre: CGPoint(x: 500, y: 85), orbRadius: 30, screen: screen)
        XCTAssertEqual(near.map(\.edge), [.bottom])
        XCTAssertGreaterThan(near[0].strength, far.first?.strength ?? 0)
        XCTAssertEqual(EdgeLight.strips(orbCentre: CGPoint(x: 500, y: 95), orbRadius: 30, screen: screen), [], "beyond a diameter")
    }

    func testCornerLightsBothEdgesAndPastTheEdgeIsFull() {
        let strips = EdgeLight.strips(orbCentre: CGPoint(x: 1010, y: -5), orbRadius: 30, screen: screen)
        XCTAssertEqual(Set(strips.map(\.edge)), [.right, .bottom])
        XCTAssertTrue(strips.allSatisfy { $0.strength == 1 })
    }

    func testFalloff() {
        XCTAssertEqual(EdgeLight.falloff(0, length: 900), 1)
        XCTAssertEqual(EdgeLight.falloff(300, length: 900), exp(-1), accuracy: 1e-6)
        XCTAssertEqual(EdgeLight.falloff(601, length: 900), 0, "cut off at 2L")
    }

    // Preference

    func testEdgeLightDefaultsOnAndSurvivesOlderSettings() throws {
        XCTAssertTrue(BubblePreferences.defaults.edgeLight)
        let prefs = try JSONDecoder().decode(BubblePreferences.self, from: Data(#"{"toasts": false}"#.utf8))
        XCTAssertTrue(prefs.edgeLight)
    }
}
