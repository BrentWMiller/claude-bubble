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

    // Further off screen, and pips further on

    func testDragClampLetsAlmostAllOfTheOrbOffScreen() {
        let side: CGFloat = 120, radius = side * 0.3   // 36
        let visible = CGRect(x: 0, y: 80, width: 1000, height: 690)
        func centre(_ o: CGPoint) -> CGPoint { CGPoint(x: o.x + side / 2, y: o.y + side / 2) }
        // Off the right: the centre stops 0.8 of a radius past the edge, so a tenth of the width shows.
        let right = centre(BubblePlacement.clampedOrigin(CGPoint(x: 2000, y: 300), side: side, screen: screen, visible: visible))
        XCTAssertEqual(right.x, screen.maxX + radius * 0.8, accuracy: 0.001)
        XCTAssertEqual((screen.maxX - (right.x - radius)) / (2 * radius), 0.1, accuracy: 0.001)
        let bottom = centre(BubblePlacement.clampedOrigin(CGPoint(x: 300, y: -900), side: side, screen: screen, visible: visible))
        XCTAssertEqual(bottom.y, screen.minY - radius * 0.8, accuracy: 0.001)
        // In a corner the limit is measured from the corner, so the pips still fit on screen.
        let corner = centre(BubblePlacement.clampedOrigin(CGPoint(x: 3000, y: -3000), side: side, screen: screen, visible: visible))
        XCTAssertEqual(hypot(corner.x - screen.maxX, corner.y - screen.minY), radius * 0.5, accuracy: 0.01)
        // The top keeps the whole orb below the menu bar.
        let top = BubblePlacement.clampedOrigin(CGPoint(x: 400, y: 2000), side: side, screen: screen, visible: visible)
        XCTAssertEqual(top.y + side / 2, visible.maxY - radius)
        // Inside: untouched.
        XCTAssertEqual(BubblePlacement.clampedOrigin(CGPoint(x: 300, y: 300), side: side, screen: screen, visible: visible),
                       CGPoint(x: 300, y: 300))
    }

    func testSavedSpotPartlyOffScreenIsKept() {
        let side: CGFloat = 120
        let saved = CGPoint(x: 1000 + 28.8 - 60, y: 300)   // centre 0.8 radius past the right edge
        XCTAssertEqual(BubblePlacement.origin(saved: saved, size: side, screenFrames: [screen], mainVisibleFrame: screen), saved)
    }

    func testPipsTurnALittleFurtherOntoTheScreen() {
        let c = CGPoint(x: 500, y: 0)
        let a = PipArc.around(centre: c, radius: r, slots: 4, visible: screen)
        // Every pip at least 16pt inside.
        XCTAssertTrue(slots(c, 4, around: a).allSatisfy { screen.insetBy(dx: 16, dy: 16).contains($0) })
        // And past the bare minimum: the lowest pip sits well above the edge.
        XCTAssertGreaterThan(slots(c, 4, around: a).map(\.y).min()!, 22)
    }

    func testEdgesBetweenDisplaysAreShared() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 100, width: 800, height: 600)
        XCTAssertEqual(EdgeLight.sharedEdges(of: a, among: [b]), [.right])
        XCTAssertEqual(EdgeLight.sharedEdges(of: b, among: [a]), [.left])
        XCTAssertEqual(EdgeLight.strips(orbCentre: CGPoint(x: 995, y: 300), orbRadius: 30, screen: a, skipping: [.right]), [])
    }

    func testDeepCornerStillShowsThePips() {
        // The orb as deep in the bottom-right corner as dragging allows (orb radius = arc radius / 1.28).
        let orbR = r / 1.28, d = orbR * 0.5 / 2.squareRoot()
        let c = CGPoint(x: 1000 + d, y: -d)
        for n in [2, 4, 5] {
            let a = PipArc.around(centre: c, radius: r, slots: n, visible: screen)
            XCTAssertTrue(slots(c, n, around: a).allSatisfy { screen.contains($0) }, "every pip on screen (\(n))")
        }
    }
}
