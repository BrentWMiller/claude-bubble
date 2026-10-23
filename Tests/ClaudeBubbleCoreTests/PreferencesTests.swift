import XCTest
@testable import ClaudeBubbleCore

final class PreferencesTests: XCTestCase {
    var defaults: UserDefaults!
    /// One fixed name, emptied around each test. (A fresh name per test left an empty plist behind in
    /// ~/Library/Preferences every time: removing a domain empties it, but the file stays.)
    let suite = "claude-bubble-tests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
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

    func testApprovalsAreOnByDefaultAndForOlderSettings() throws {
        XCTAssertTrue(BubblePreferences.defaults.approvals)
        defaults.set(Data(#"{"diameter": 90}"#.utf8), forKey: BubblePreferences.key)
        XCTAssertTrue(BubblePreferences.load(from: defaults).approvals)
        var p = BubblePreferences.defaults
        p.approvals = false
        p.save(to: defaults)
        XCTAssertFalse(BubblePreferences.load(from: defaults).approvals)
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
        p.diameter = 2000
        p.opacity = 7
        XCTAssertEqual(p.clamped().diameter, 800)
        XCTAssertEqual(p.clamped().opacity, 1)
    }

    func testUnknownPresetFallsBack() {
        var p = BubblePreferences.defaults
        p.presetName = "Gone"
        p.save(to: defaults)
        XCTAssertEqual(BubblePreferences.load(from: defaults).presetName, "Agents view")
    }

    func testBigOrbsGetMoreDotsNotBiggerOnes() {
        XCTAssertEqual(OrbGeometry.pointCount(diameter: 72), OrbGeometry.pointCount)
        XCTAssertEqual(OrbGeometry.pointCount(diameter: 500), OrbGeometry.pointCount)
        XCTAssertEqual(OrbGeometry.pointCount(diameter: 800), 13312, "as the area grows")
        XCTAssertEqual(OrbGeometry.dotSizingSide(120), 120)
        XCTAssertEqual(OrbGeometry.dotSizingSide(800 / 0.6), 500 / 0.6, accuracy: 0.001)
    }

    func testPipsGrowPastTheOldLargestOrb() {
        XCTAssertEqual(PipArc.scale(diameter: 72), 1)
        XCTAssertEqual(PipArc.scale(diameter: 160), 1)
        XCTAssertEqual(PipArc.scale(diameter: 800), 5)
        XCTAssertEqual(PipArc.scale(radius: 400 * PipArc.radiusScale), 5, accuracy: 0.0001)
    }

    func testIslandWidth() {
        XCTAssertEqual(BubblePreferences.defaults.islandWidth, 1)
        var p = BubblePreferences.defaults
        p.islandWidth = 9
        XCTAssertEqual(p.clamped().islandWidth, IslandLayout.maxWidth)
        p.islandWidth = 0.1
        XCTAssertEqual(p.clamped().islandWidth, IslandLayout.minWidth)
        defaults.set(Data(#"{"diameter": 90}"#.utf8), forKey: BubblePreferences.key)
        XCTAssertEqual(BubblePreferences.load(from: defaults).islandWidth, 1, "older settings")
    }

    func testPanelSide() {
        XCTAssertEqual(OrbSize.panelSide(forDiameter: 72), 120, accuracy: 0.001)
        XCTAssertEqual(OrbSize.panelSide(forDiameter: 10), 40 / 0.6, accuracy: 0.001)
        XCTAssertEqual(OrbSize.panelSide(forDiameter: 2000), 800 / 0.6, accuracy: 0.001)
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

    func testSoundVolumeDefaultsFullAndClamps() throws {
        XCTAssertEqual(BubblePreferences.defaults.soundVolume, 1)
        var p = BubblePreferences.defaults
        p.soundVolume = 0.4
        p.save(to: defaults)
        XCTAssertEqual(BubblePreferences.load(from: defaults).soundVolume, 0.4)
        p.soundVolume = 3
        XCTAssertEqual(p.clamped().soundVolume, 1)
        p.soundVolume = -1
        XCTAssertEqual(p.clamped().soundVolume, 0)
        let old = Data(#"{"diameter": 90}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(BubblePreferences.self, from: old).soundVolume, 1, "older settings")
    }

    func testUsageDefaultsOnAndSurvivesOlderSettings() throws {
        XCTAssertTrue(BubblePreferences.defaults.usage)
        let old = Data(#"{"diameter": 90, "toasts": false}"#.utf8)
        let prefs = try JSONDecoder().decode(BubblePreferences.self, from: old)
        XCTAssertTrue(prefs.usage)
        XCTAssertFalse(prefs.toasts)
    }

    func testCatchUpDefaults() {
        let d = BubblePreferences.defaults
        XCTAssertTrue(d.catchUp)
        XCTAssertFalse(d.catchUpSummaries)
        XCTAssertEqual(d.awayMinutes, 10)
        XCTAssertEqual(BubblePreferences.awayMinuteChoices, [5, 10, 15, 30, 60])
    }

    func testOlderSavedPreferencesGetCatchUpDefaults() throws {
        let old = try JSONEncoder().encode(["sounds": true])   // no catch-up keys
        let p = try JSONDecoder().decode(BubblePreferences.self, from: old)
        XCTAssertTrue(p.catchUp)
        XCTAssertFalse(p.catchUpSummaries)
        XCTAssertEqual(p.awayMinutes, 10)
    }

    func testAwayMinutesOutsideTheChoicesFallsBackToTen() throws {
        let bad = try JSONEncoder().encode(["awayMinutes": 7])
        XCTAssertEqual(try JSONDecoder().decode(BubblePreferences.self, from: bad).awayMinutes, 10)
    }
}
