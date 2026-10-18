import XCTest
@testable import ClaudeBubbleCore

final class StyleMorphTests: XCTestCase {
    func testEaseRunsFromZeroToOne() {
        XCTAssertEqual(StyleMorph.ease(0), 0)
        XCTAssertEqual(StyleMorph.ease(1), 1)
        XCTAssertEqual(StyleMorph.ease(0.5), 0.5, accuracy: 1e-9)
        XCTAssertLessThan(StyleMorph.ease(0.1), 0.1, "starts gently")
        XCTAssertGreaterThan(StyleMorph.ease(0.9), 0.9, "lands gently")
    }

    func testPathStartsAndEndsOnTheEndpoints() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 400, y: 300)
        let c = StyleMorph.arcControl(from: a, to: b)
        XCTAssertEqual(StyleMorph.point(on: a, c, b, at: 0), a)
        XCTAssertEqual(StyleMorph.point(on: a, c, b, at: 1), b)
    }

    func testArcBowsUpward() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 400, y: 0)
        let mid = StyleMorph.point(on: a, StyleMorph.arcControl(from: a, to: b), b, at: 0.5)
        XCTAssertEqual(mid.x, 200, accuracy: 1e-9)
        XCTAssertGreaterThan(mid.y, 0)
        let back = StyleMorph.point(on: b, StyleMorph.arcControl(from: b, to: a), a, at: 0.5)
        XCTAssertGreaterThan(back.y, 0, "either direction")
    }

    func testNoArcForATinyHop() {
        let a = CGPoint(x: 10, y: 10)
        XCTAssertEqual(StyleMorph.arcControl(from: a, to: a), a)
    }

    func testOrbFrameIsCentred() {
        XCTAssertEqual(StyleMorph.orbFrame(centre: CGPoint(x: 100, y: 50), side: 28), CGRect(x: 86, y: 36, width: 28, height: 28))
    }
}
