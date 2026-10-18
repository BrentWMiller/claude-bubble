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

    func testOverFiveSummarisesThenPlaysTheLatestFour() {
        let all = (0..<8).map { held(.finished, "s\($0)") }
        let plan = CatchUp.plan(all)
        XCTAssertEqual(plan.first?.kind, .catchUp)
        XCTAssertEqual(plan.first?.name, "While you were away")
        XCTAssertEqual(plan.dropFirst().map(\.name), ["s4", "s5", "s6", "s7"])
        XCTAssertEqual(plan.map(\.delay), [0, 0.35, 0.7, 1.05, 1.4], accuracy: 1e-9)
    }

    func testSummaryStaysOnTheStackThroughTheCatchUp() {
        let q = ToastQueue()
        for item in CatchUp.plan((0..<9).map { held(.finished, "s\($0)") }) {
            q.push(item.kind, name: item.name, text: item.text, now: item.delay)
        }
        XCTAssertTrue(q.layout(expanded: false).contains { $0.kind == .catchUp && $0.showing })
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
        XCTAssertEqual(q.scale / p.scale, 0.28, accuracy: 0.01, "the default")
        quiet.quiet = false
        for _ in 0..<200 { q = quiet.step(dt: 0.02); p = plain.step(dt: 0.02) }
        XCTAssertEqual(q.scale / p.scale, 1, accuracy: 0.01)
    }

    func testQuietOrbIsTheIslandsOrbSizeWhateverTheOrbsSize() {
        XCTAssertEqual(OrbSize.quietScale(forDiameter: 72) * 72, IslandLayout.orbSize * 0.6, accuracy: 0.001)
        XCTAssertEqual(OrbSize.quietScale(forDiameter: 400) * 400, IslandLayout.orbSize * 0.6, accuracy: 0.001)
        let a = OrbAnimator(state: .working, random: { 0.5 }), plain = OrbAnimator(state: .working, random: { 0.5 })
        a.quietScale = Float(OrbSize.quietScale(forDiameter: 200))
        a.quiet = true
        var q = a.step(dt: 0.02), p = plain.step(dt: 0.02)
        for _ in 0..<200 { q = a.step(dt: 0.02); p = plain.step(dt: 0.02) }
        XCTAssertEqual(q.scale / p.scale, Float(OrbSize.quietScale(forDiameter: 200)), accuracy: 0.002)
    }

    // Preference

    func testQuietDefaultsOffAndIsSaved() throws {
        XCTAssertFalse(BubblePreferences.defaults.quiet)
        XCTAssertFalse(try JSONDecoder().decode(BubblePreferences.self, from: Data(#"{"toasts": true}"#.utf8)).quiet)
        var p = BubblePreferences.defaults
        p.quiet = true
        XCTAssertTrue(try JSONDecoder().decode(BubblePreferences.self, from: JSONEncoder().encode(p)).quiet)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
