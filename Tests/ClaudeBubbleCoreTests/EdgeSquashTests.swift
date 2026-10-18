import XCTest
@testable import ClaudeBubbleCore

final class EdgeSquashTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testNowhereNearAnEdge() {
        XCTAssertEqual(EdgeSquash.edges(centre: CGPoint(x: 500, y: 400), radius: 50, screen: screen, top: 775),
                       SIMD4(repeating: EdgeSquash.far))
    }

    func testPressedIntoTheRightEdge() {
        // Centre 20pt from the edge, radius 50: the edge is 0.4 radii out, so 60% of the radius is past it.
        let e = EdgeSquash.edges(centre: CGPoint(x: 980, y: 400), radius: 50, screen: screen, top: 775)
        XCTAssertEqual(e.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(e.y, 1)
        XCTAssertEqual(e.z, 1)
        XCTAssertEqual(e.w, 1)
    }

    func testACornerSquashesTwoEdges() {
        let e = EdgeSquash.edges(centre: CGPoint(x: 30, y: 10), radius: 50, screen: screen, top: 775)
        XCTAssertEqual(e.z, 0.6, accuracy: 0.0001, "left")
        XCTAssertEqual(e.w, 0.2, accuracy: 0.0001, "bottom")
    }

    func testTheTopIsUnderTheMenuBar() {
        let e = EdgeSquash.edges(centre: CGPoint(x: 500, y: 760), radius: 50, screen: screen, top: 775)
        XCTAssertEqual(e.y, 0.3, accuracy: 0.0001)
    }

    func testPastTheEdgeReadsNegative() {
        XCTAssertLessThan(EdgeSquash.edges(centre: CGPoint(x: 1020, y: 400), radius: 50, screen: screen, top: 775).x, 0)
    }

    func testAnEdgeSharedWithAnotherDisplayNeverSquashes() {
        let e = EdgeSquash.edges(centre: CGPoint(x: 990, y: 400), radius: 50, screen: screen, top: 775, shared: [.right])
        XCTAssertEqual(e.x, EdgeSquash.far)
    }

    func testTheSpringSettlesOnItsTarget() {
        var s = EdgeSquash.Spring()
        let target = SIMD4<Float>(0.4, 1, 1, 1)
        for _ in 0..<120 { s.step(toward: target, dt: 1 / 60) }
        XCTAssertEqual(s.value.x, 0.4, accuracy: 0.001)
    }

    func testReleasingWobblesPastRound() {
        var s = EdgeSquash.Spring()
        for _ in 0..<120 { s.step(toward: [0.4, 1, 1, 1], dt: 1 / 60) }
        var most: Float = 0
        for _ in 0..<60 {
            s.step(toward: SIMD4(repeating: EdgeSquash.far), dt: 1 / 60)
            most = max(most, s.value.x)
        }
        XCTAssertGreaterThan(most, 1.05, "overshoots: the jiggle")
        XCTAssertEqual(s.value.x, 1, accuracy: 0.02, "and settles round")
    }

    func testALongFrameStaysStable() {
        var s = EdgeSquash.Spring()
        s.step(toward: [0.2, 1, 1, 1], dt: 5)
        XCTAssertTrue(s.value.x.isFinite)
        XCTAssertLessThan(abs(s.value.x - 0.2), 1)
    }
}
