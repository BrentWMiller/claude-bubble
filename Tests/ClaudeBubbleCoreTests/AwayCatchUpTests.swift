import XCTest
@testable import ClaudeBubbleCore

final class AwayCatchUpTests: XCTestCase {
    private func s(_ id: String, _ state: BubbleState, at t: TimeInterval) -> Session {
        Session(id: id, state: state, updatedAt: Date(timeIntervalSince1970: t))
    }

    func testChangedIsNewStateOrNewTurns() {
        let marks = AwayCatchUp.marks([s("a", .working, at: 0), s("b", .working, at: 0), s("c", .idle, at: 0)], offsets: [:])
        let now = [s("a", .needs, at: 0), s("b", .working, at: 200), s("c", .idle, at: 0), s("d", .working, at: 0)]
        XCTAssertEqual(AwayCatchUp.changed(now, since: marks, leftAt: Date(timeIntervalSince1970: 100)).map(\.id), ["a", "b", "d"])
    }

    func testMarksKeepTranscriptOffsets() {
        let marks = AwayCatchUp.marks([s("a", .working, at: 0), s("b", .idle, at: 0)], offsets: ["a": 42])
        XCTAssertEqual(marks["a"]?.transcriptOffset, 42)
        XCTAssertEqual(marks["b"]?.transcriptOffset, 0)
    }

    func testEndedSessionsAreDropped() {
        let marks = AwayCatchUp.marks([s("a", .working, at: 0)], offsets: [:])
        XCTAssertTrue(AwayCatchUp.changed([], since: marks, leftAt: Date(timeIntervalSince1970: 100)).isEmpty)
        let c = AwayCatchUp(leftAt: .distantPast, items: [AwayItem(sessionID: "a", line: .plain("x"))], seen: false)
        XCTAssertTrue(c.grouped(current: [:]).isEmpty)
    }

    func testGroupsFollowCurrentState() {
        let c = AwayCatchUp(leftAt: .distantPast, items: [AwayItem(sessionID: "a", line: .plain("x")),
                                                     AwayItem(sessionID: "b", line: .plain("y"))], seen: false)
        let before = c.grouped(current: ["a": s("a", .needs, at: 0), "b": s("b", .idle, at: 0)])
        XCTAssertEqual(before.map(\.0), [.needsYou, .finished])
        let after = c.grouped(current: ["a": s("a", .working, at: 0), "b": s("b", .idle, at: 0)])   // approved elsewhere
        XCTAssertEqual(after.map(\.0), [.finished, .stillWorking])
        XCTAssertEqual(AwayGroup.allCases.map(\.title), ["NEEDS YOU", "FINISHED", "FAILED", "STILL WORKING"])
        XCTAssertEqual(AwayGroup.of(.error), .failed)
    }

    func testMergeKeepsEarlierItems() {
        let early = AwayCatchUp(leftAt: Date(timeIntervalSince1970: 10), items: [AwayItem(sessionID: "a", line: .plain("old a")),
                                                                            AwayItem(sessionID: "b", line: .plain("b"))], seen: false)
        let late = AwayCatchUp(leftAt: Date(timeIntervalSince1970: 500), items: [AwayItem(sessionID: "a", line: .plain("new a"))], seen: false)
        let m = early.merging(late)
        XCTAssertEqual(m.leftAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(m.items.map { $0.line.text }, ["new a", "b"])
    }

    func testLineText() {
        XCTAssertEqual(AwayLine.pending(plain: "p").text, "p")
        XCTAssertNil(AwayLine.pending(plain: nil).text)
        XCTAssertEqual(AwayLine.written("w", at: .distantPast).text, "w")
    }

    func testHeightIsCapped() {
        let many = (0..<20).map { AwayItem(sessionID: "\($0)", line: .plain("x")) }
        XCTAssertEqual(AwayLayout.height(groups: [(.finished, many)], approvalHeights: [:], footer: true), AwayLayout.maxHeight)
        XCTAssertEqual(AwayLayout.height(groups: [(.finished, [many[0]])], approvalHeights: [:], footer: false), 52 + 30 + 66)
        let needs: CGFloat = 52 + 30 + 66 * 2 + (100 + 12) + 48 + 44   // one with an approval card, one with reply buttons
        XCTAssertEqual(AwayLayout.height(groups: [(.needsYou, [many[0], many[1]])], approvalHeights: ["0": 100], footer: true), needs)
    }

    func testViewKeepsTheListsHeightSoThePointerStaysOnIt() {
        let one = [(AwayGroup.finished, [AwayItem(sessionID: "a", line: .plain("x"))])]
        XCTAssertEqual(AwayLayout.height(groups: one, approvalHeights: [:], footer: false, atLeast: 400), 400)
        XCTAssertEqual(AwayLayout.height(groups: one, approvalHeights: [:], footer: false, atLeast: 100), 52 + 30 + 66)
        XCTAssertEqual(AwayLayout.height(groups: one, approvalHeights: [:], footer: false, atLeast: 600), 600)
    }
}
