import XCTest
@testable import ClaudeBubbleCore

final class PRStatusTests: XCTestCase {
    func parse(_ json: String) -> PRStatus? { PRStatus.parse(Data(json.utf8)) }

    func check(_ status: String, _ conclusion: String?) -> String {
        #"{"__typename":"CheckRun","status":"\#(status)","conclusion":\#(conclusion.map { "\"\($0)\"" } ?? "null")}"#
    }

    func testOpenApprovedPassing() throws {
        let s = try XCTUnwrap(parse(#"{"state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[\#(check("COMPLETED", "SUCCESS")),\#(check("COMPLETED", "SKIPPED"))]}"#))
        XCTAssertEqual(s, PRStatus(state: .open, checks: .passing, review: .approved))
    }

    func testAnyFailureFails() throws {
        let s = try XCTUnwrap(parse(#"{"state":"OPEN","isDraft":false,"reviewDecision":"","statusCheckRollup":[\#(check("COMPLETED", "SUCCESS")),\#(check("COMPLETED", "FAILURE")),\#(check("IN_PROGRESS", nil))]}"#))
        XCTAssertEqual(s.checks, .failing, "a failure beats pending")
        XCTAssertEqual(s.review, .none)
    }

    func testPendingAndStatusContexts() throws {
        let s = try XCTUnwrap(parse(#"{"state":"OPEN","isDraft":true,"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[\#(check("COMPLETED", "SUCCESS")),{"__typename":"StatusContext","state":"PENDING"}]}"#))
        XCTAssertEqual(s.checks, .pending)
        XCTAssertEqual(s.state, .draft)
        XCTAssertEqual(s.review, .changesRequested)
        let failed = try XCTUnwrap(parse(#"{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"StatusContext","state":"ERROR"}]}"#))
        XCTAssertEqual(failed.checks, .failing)
    }

    func testMergedAndClosed() throws {
        XCTAssertEqual(parse(#"{"state":"MERGED","isDraft":false,"statusCheckRollup":[]}"#)?.state, .merged)
        XCTAssertEqual(parse(#"{"state":"CLOSED","isDraft":false,"statusCheckRollup":[]}"#)?.state, .closed)
        XCTAssertEqual(parse(#"{"state":"OPEN","isDraft":false,"statusCheckRollup":[]}"#)?.checks, PRStatus.Checks.none)
        XCTAssertNil(parse("not json"))
    }

    // Applying to sessions

    let prURL = URL(string: "https://github.com/o/r/pull/7259")!

    func session(review: Bool) -> Session {
        var s = Session(id: "s", state: .idle, updatedAt: Date(), detail: "Completed", reviewReady: review)
        s.links = [SessionLink(kind: .pr, label: "#7259", url: prURL)]
        return s
    }

    func testStatusLandsOnTheChip() {
        let st = PRStatus(state: .open, checks: .failing, review: .none)
        let out = PRStatus.apply([prURL: st], to: [session(review: true)])
        XCTAssertEqual(out.first?.links.first?.status, st)
        XCTAssertEqual(out.first?.reviewReady, true)
    }

    func testMergedClearsReadyForReview() {
        let out = PRStatus.apply([prURL: PRStatus(state: .merged, checks: .passing, review: .approved)], to: [session(review: true)])
        XCTAssertEqual(out.first?.reviewReady, false)
        XCTAssertEqual(out.first?.detail, "Merged #7259")
    }

    func testUnknownStatusChangesNothing() {
        let out = PRStatus.apply([:], to: [session(review: true)])
        XCTAssertEqual(out.first?.reviewReady, true)
        XCTAssertNil(out.first?.links.first?.status)
    }
}
