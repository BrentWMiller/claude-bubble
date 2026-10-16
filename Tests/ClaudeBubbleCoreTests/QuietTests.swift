import XCTest
@testable import ClaudeBubbleCore

final class QuietTests: XCTestCase {
    func held(_ kind: ToastKind, _ name: String = "s") -> HeldToast { HeldToast(kind: kind, name: name, text: nil) }

    // Catch-up

    func testNothingHeldPlaysNothing() {
        XCTAssertEqual(CatchUp.plan([]), [])
    }

    func testUpToFivePlayInOrderSpacedOut() {
        let plan = CatchUp.plan([held(.finished, "a"), held(.needs, "b"), held(.error, "c")])
        XCTAssertEqual(plan.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(plan.map(\.delay), [0, 0.35, 0.7])
    }

    func testOverFiveSummarisesThenPlaysTheLatestFive() {
        let all = (0..<8).map { held(.finished, "s\($0)") }
        let plan = CatchUp.plan(all)
        XCTAssertEqual(plan.first?.kind, .catchUp)
        XCTAssertEqual(plan.first?.name, "While you were away")
        XCTAssertEqual(plan.dropFirst().map(\.name), ["s3", "s4", "s5", "s6", "s7"])
        XCTAssertEqual(plan.map(\.delay), [0, 0.35, 0.7, 1.05, 1.4, 1.75].map { $0 }, accuracy: 1e-9)
    }

    func testSummaryWording() {
        XCTAssertEqual(CatchUp.summary([held(.finished), held(.review), held(.allDone), held(.needs), held(.error), held(.started)]),
                       "3 finished · 1 needs you · 1 error")
        XCTAssertEqual(CatchUp.summary([held(.needs), held(.needs), held(.error), held(.error)]), "2 need you · 2 errors")
        XCTAssertEqual(CatchUp.summary([held(.started), held(.usageLow), held(.resumed)]), "3 updates")
    }

    func testHeldTextTravelsWithTheToast() {
        let plan = CatchUp.plan([HeldToast(kind: .usageLow, name: "Usage", text: "25% left · resets 1h")])
        XCTAssertEqual(plan.first?.text, "25% left · resets 1h")
    }

    // Island

    func testQuietRanksBelowHoverAndAboveEverythingElse() {
        let now = Date()
        let needs = Session(id: "n", state: .needs, updatedAt: now, stateSince: now)
        XCTAssertEqual(IslandMode.choose(sessions: [needs], now: now, hovering: false, doneAt: now, quiet: true), .quiet)
        XCTAssertEqual(IslandMode.choose(sessions: [needs], now: now, hovering: true, doneAt: nil, quiet: true), .hover)
        XCTAssertEqual(IslandLayout.size(mode: .quiet, dock: .top, rest: .live, pips: 3, rows: 3), CGSize(width: 16, height: 16))
        XCTAssertEqual(IslandLayout.size(mode: .quiet, dock: .left, rest: .live, pips: 3, rows: 3), CGSize(width: 16, height: 16))
    }

    // Orb

    func testOrbShrinksToADotAndBack() {
        let quiet = OrbAnimator(state: .working, random: { 0.5 }), plain = OrbAnimator(state: .working, random: { 0.5 })
        quiet.quiet = true
        var q = quiet.step(dt: 0.02), p = plain.step(dt: 0.02)
        for _ in 0..<200 { q = quiet.step(dt: 0.02); p = plain.step(dt: 0.02) }
        XCTAssertEqual(q.scale / p.scale, 0.28, accuracy: 0.01)
        quiet.quiet = false
        for _ in 0..<200 { q = quiet.step(dt: 0.02); p = plain.step(dt: 0.02) }
        XCTAssertEqual(q.scale / p.scale, 1, accuracy: 0.01)
    }

    // Preference

    func testAnyFocusDefaultsOff() throws {
        XCTAssertFalse(BubblePreferences.defaults.quietAnyFocus)
        XCTAssertFalse(try JSONDecoder().decode(BubblePreferences.self, from: Data(#"{"toasts": true}"#.utf8)).quietAnyFocus)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
