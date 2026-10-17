import XCTest
@testable import ClaudeBubbleCore

final class PaletteColorsTests: XCTestCase {
    func testPresetsKeepTodaysIdleAndDoneColours() {
        XCTAssertEqual(OrbPalette.originalDesign.done, OrbAnimator.doneGreen)
        XCTAssertEqual(OrbPalette.originalDesign.quiet, OrbPalette.defaultQuiet)
    }

    // Palettes saved before Idle and All done could be edited still load, with those two at their defaults.
    func testOlderSavedPalettesLoad() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(OrbPalette.ocean)) as? [String: Any])
        json["quiet"] = nil
        json["done"] = nil
        let old = try JSONSerialization.data(withJSONObject: json)
        let loaded = try JSONDecoder().decode(OrbPalette.self, from: old)
        XCTAssertEqual(loaded, OrbPalette.ocean)
    }

    func testEveryEditableColourRoundTrips() throws {
        var p = OrbPalette.originalDesign
        for (i, color) in PaletteColor.allCases.enumerated() {
            p[color] = [Float(i) / 10, 0.5, 0.25]
        }
        for (i, color) in PaletteColor.allCases.enumerated() {
            XCTAssertEqual(p[color], [Float(i) / 10, 0.5, 0.25], "\(color)")
        }
        XCTAssertEqual(p.idle.swatch, p[.completed])
        XCTAssertEqual(p.done.swatch, p[.done])
        XCTAssertEqual(try JSONDecoder().decode(OrbPalette.self, from: JSONEncoder().encode(p)), p)
    }

    func testLabels() {
        XCTAssertEqual(PaletteColor.allCases.map(\.label), ["Completed", "Working", "Needs you", "Error", "Idle", "All done"])
    }
}
