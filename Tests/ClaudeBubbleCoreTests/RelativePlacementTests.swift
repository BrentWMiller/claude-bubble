import XCTest
@testable import ClaudeBubbleCore

final class RelativePlacementTests: XCTestCase {
    let big = CGRect(x: 0, y: 25, width: 2560, height: 1390)
    let small = CGRect(x: 2560, y: 0, width: 1440, height: 875)

    func testSpotIsTheCentreFraction() {
        let frame = CGRect(x: 1220, y: 25 + 139 - 60, width: 120, height: 120)   // centred at 50% across, 10% up
        let spot = RelativePlacement.spot(of: frame, in: big)
        XCTAssertEqual(spot.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(spot.y, 0.1, accuracy: 0.0001)
    }

    func testOriginRoundTrips() {
        let frame = CGRect(x: 400, y: 600, width: 120, height: 120)
        let back = RelativePlacement.origin(for: RelativePlacement.spot(of: frame, in: big), side: 120, in: big)
        XCTAssertEqual(back.x, 400, accuracy: 0.001)
        XCTAssertEqual(back.y, 600, accuracy: 0.001)
    }

    func testSameSpotOnAnotherDisplay() {
        let o = RelativePlacement.origin(for: CGPoint(x: 0.5, y: 0.5), side: 120, in: small)
        XCTAssertEqual(o, CGPoint(x: 2560 + 720 - 60, y: 437.5 - 60))
    }

    func testClampsOnASmallerDisplay() {
        // A spot hugging the bottom-right edge, with a big orb, must still fit fully.
        let o = RelativePlacement.origin(for: CGPoint(x: 0.99, y: 0.01), side: 266, in: small)
        XCTAssertEqual(o.x, small.maxX - 266)
        XCTAssertEqual(o.y, small.minY)
    }
}
