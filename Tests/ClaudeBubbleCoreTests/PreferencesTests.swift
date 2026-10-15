import XCTest
@testable import ClaudeBubbleCore

final class PreferencesTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() {
        suite = "claude-bubble-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaults() {
        let p = BubblePreferences.load(from: defaults)
        XCTAssertEqual(p, .defaults)
        XCTAssertEqual(p.palette, .agentsView)
        XCTAssertEqual(p.presetName, "Agents view")
        XCTAssertFalse(p.customized)
        XCTAssertEqual(p.diameter, 72)
        XCTAssertEqual(p.opacity, 1)
        XCTAssertFalse(p.followPointer)
        XCTAssertNil(p.relativeSpot)
    }

    func testSaveLoadRoundTrip() {
        var p = BubblePreferences.defaults
        p.palette = .blue
        p.presetName = "Blue"
        p.customized = true
        p.diameter = 110
        p.opacity = 0.6
        p.followPointer = true
        p.relativeSpot = [0.5, 0.08]
        p.save(to: defaults)
        XCTAssertEqual(BubblePreferences.load(from: defaults), p)
    }

    func testCorruptBlobGivesDefaults() {
        defaults.set(Data("{ nope".utf8), forKey: BubblePreferences.key)
        XCTAssertEqual(BubblePreferences.load(from: defaults), .defaults)
    }

    func testClampsOutOfRangeValues() {
        var p = BubblePreferences.defaults
        p.diameter = 5
        p.opacity = 0
        p.save(to: defaults)
        let loaded = BubblePreferences.load(from: defaults)
        XCTAssertEqual(loaded.diameter, 40)
        XCTAssertEqual(loaded.opacity, 0.3)
        p.diameter = 999
        p.opacity = 7
        XCTAssertEqual(p.clamped().diameter, 160)
        XCTAssertEqual(p.clamped().opacity, 1)
    }

    func testUnknownPresetFallsBack() {
        var p = BubblePreferences.defaults
        p.presetName = "Gone"
        p.save(to: defaults)
        XCTAssertEqual(BubblePreferences.load(from: defaults).presetName, "Agents view")
    }

    func testPanelSide() {
        XCTAssertEqual(OrbSize.panelSide(forDiameter: 72), 120, accuracy: 0.001)
        XCTAssertEqual(OrbSize.panelSide(forDiameter: 10), 40 / 0.6, accuracy: 0.001)
        XCTAssertEqual(OrbSize.panelSide(forDiameter: 500), 160 / 0.6, accuracy: 0.001)
    }

    func testSoundsAreOnByDefaultAndToggle() throws {
        XCTAssertTrue(BubblePreferences.defaults.sounds)
        var p = BubblePreferences.defaults
        p.sounds = false
        p.save(to: defaults)
        XCTAssertFalse(BubblePreferences.load(from: defaults).sounds)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(BubblePreferences.defaults)) as? [String: Any])
        json.removeValue(forKey: "sounds")
        XCTAssertTrue(try JSONDecoder().decode(BubblePreferences.self, from: JSONSerialization.data(withJSONObject: json)).sounds,
                      "settings saved before sounds existed default to on")
    }
}
