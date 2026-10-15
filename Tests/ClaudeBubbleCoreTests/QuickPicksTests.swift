import XCTest
@testable import ClaudeBubbleCore

final class QuickPicksTests: XCTestCase {
    func testSizeOptions() {
        XCTAssertEqual(QuickPicks.sizes.map(\.label), ["Small", "Medium", "Large", "Extra large"])
        XCTAssertEqual(QuickPicks.sizes.map(\.diameter), [48, 72, 104, 144])
    }

    func testSizeCheckmarkOnlyOnAnExactMatch() {
        XCTAssertEqual(QuickPicks.checkedSize(72), 72)
        XCTAssertEqual(QuickPicks.checkedSize(72.3), 72)
        XCTAssertNil(QuickPicks.checkedSize(90))
    }

    func testOpacityCheckmarkOnlyOnAnExactMatch() {
        XCTAssertEqual(QuickPicks.opacities, [1, 0.8, 0.6, 0.4])
        XCTAssertEqual(QuickPicks.checkedOpacity(0.8), 0.8)
        XCTAssertEqual(QuickPicks.checkedOpacity(0.6001), 0.6)
        XCTAssertNil(QuickPicks.checkedOpacity(0.75))
    }

    func testPresetCheckmarkAndTitle() {
        var p = BubblePreferences.defaults
        XCTAssertTrue(QuickPicks.isChecked(preset: "Agents view", in: p))
        XCTAssertFalse(QuickPicks.isChecked(preset: "Blue", in: p))
        XCTAssertEqual(QuickPicks.title(forPreset: "Agents view", in: p), "Agents view")
        p.customized = true
        XCTAssertFalse(QuickPicks.isChecked(preset: "Agents view", in: p), "a customized palette isn't the preset")
        XCTAssertEqual(QuickPicks.title(forPreset: "Agents view", in: p), "Agents view (customized)")
        XCTAssertEqual(QuickPicks.title(forPreset: "Blue", in: p), "Blue")
    }
}
