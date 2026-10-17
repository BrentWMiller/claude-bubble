import XCTest
@testable import ClaudeBubbleCore

final class SiteExportTests: XCTestCase {
    func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: SiteExport.json(version: "0.1.3")) as? [String: Any])
    }

    func testStoryIsTheAppsScriptedSession() throws {
        let story = try XCTUnwrap(object()["story"] as? [[String: Any]])
        XCTAssertEqual(story.count, SimulatorStory.session.count)
        XCTAssertEqual(story.map { $0["duration"] as? Double }, SimulatorStory.session.map(\.duration))
        XCTAssertEqual(story.first?["state"] as? String, "working")
        XCTAssertEqual(story.last?["state"] as? String, "done", "the story ends finished, which the site shows as done")
        XCTAssertTrue(story.contains { $0["state"] as? String == "needs" })
        XCTAssertTrue(story.contains { $0["state"] as? String == "error" })
        XCTAssertTrue(story.contains { ($0["subagents"] as? Int ?? 0) > 0 })
    }

    func testMotionsCarryTheOrbsWorkModes() throws {
        let motions = try XCTUnwrap(object()["motions"] as? [String: [String: String]])
        XCTAssertEqual(Set(motions.keys), Set(Motion.allCases.map(\.rawValue)))
        XCTAssertEqual(motions["read"]?["work"], "converge")
        XCTAssertEqual(motions["waiting"]?["work"], "wait")
        XCTAssertEqual(motions["edit"]?["verb"], "Editing")
        XCTAssertEqual(motions["bash"]?["summary"], "Running a command")
    }

    func testPaletteIsTheClaudeThemeInTheOrbsFormat() throws {
        let palette = try XCTUnwrap(object()["palette"] as? [String: [String: [Double]]])
        XCTAssertEqual(Set(palette.keys), ["idle", "working", "needs", "error", "done"])
        let working = try XCTUnwrap(palette["working"])
        XCTAssertEqual(working["C1"]?.map { ($0 * 100).rounded() }, [100, 46, 20])
        XCTAssertEqual(Set(working.keys), ["C1", "C2", "C3", "H", "swatch"])
    }

    func testToastsUseTheAppsWording() throws {
        let toasts = try XCTUnwrap(object()["toasts"] as? [String: [String: String]])
        XCTAssertEqual(toasts["needs"]?["text"], ToastKind.needs.text)
        XCTAssertEqual(toasts["allDone"]?["text"], "complete")
        XCTAssertTrue(toasts["error"]?["color"]?.hasPrefix("#") == true)
    }

    func testIslandSizesComeFromTheLayout() throws {
        let island = try XCTUnwrap(object()["island"] as? [String: Double])
        XCTAssertEqual(island["restWidth"], Double(IslandLayout.size(mode: .rest, dock: .top, rest: .live, pips: 3, rows: 3).width))
        XCTAssertEqual(island["cornerRadius"], Double(IslandLayout.cornerRadius))
        XCTAssertEqual(try object()["version"] as? String, "0.1.3")
    }
}
