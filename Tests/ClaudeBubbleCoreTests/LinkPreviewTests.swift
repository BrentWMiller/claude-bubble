import XCTest
@testable import ClaudeBubbleCore

final class LinkPreviewTests: XCTestCase {
    func testPullRequest() throws {
        let json = #"""
        {"title":"CORE: Team role and member warnings","state":"OPEN","author":{"login":"octocat"},
         "additions":412,"deletions":88,"changedFiles":9,"reviewDecision":"CHANGES_REQUESTED",
         "latestReviews":[{"author":{"login":"monalisa"},"state":"CHANGES_REQUESTED"},{"author":{"login":"kit"},"state":"COMMENTED"}],
         "statusCheckRollup":[
           {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},
           {"__typename":"CheckRun","name":"unit","status":"COMPLETED","conclusion":"SUCCESS"},
           {"__typename":"CheckRun","name":"docs","status":"COMPLETED","conclusion":"SKIPPED"},
           {"__typename":"CheckRun","name":"e2e (chromium)","status":"IN_PROGRESS","conclusion":null},
           {"__typename":"StatusContext","context":"ci/deploy","state":"ERROR"},
           {"__typename":"StatusContext","context":"ci/preview","state":"PENDING"}]}
        """#
        let p = try XCTUnwrap(LinkPreview.parsePullRequest(Data(json.utf8)))
        XCTAssertEqual(p.title, "CORE: Team role and member warnings")
        XCTAssertEqual(p.author, "octocat")
        XCTAssertEqual(p.additions, 412)
        XCTAssertEqual(p.deletions, 88)
        XCTAssertEqual(p.changedFiles, 9)
        XCTAssertEqual(p.failed, ["lint", "ci/deploy"])
        XCTAssertEqual(p.passed, 2, "success and skipped count as passed")
        XCTAssertEqual(p.running, 2)
        XCTAssertEqual(p.review, "Changes requested by monalisa")
        XCTAssertFalse(p.final)
    }

    func testApprovedAndMerged() throws {
        let json = #"{"title":"T","state":"MERGED","author":{"login":"a"},"additions":1,"deletions":0,"changedFiles":1,"reviewDecision":"APPROVED","latestReviews":[{"author":{"login":"x"},"state":"APPROVED"},{"author":{"login":"y"},"state":"APPROVED"}],"statusCheckRollup":[]}"#
        let p = try XCTUnwrap(LinkPreview.parsePullRequest(Data(json.utf8)))
        XCTAssertEqual(p.review, "Approved by x, y")
        XCTAssertTrue(p.final, "merged never changes again")
        XCTAssertEqual(p.failed, [])
    }

    func testIssue() throws {
        let json = #"""
        {"title":"Members can't change roles","state":"CLOSED",
         "labels":[{"name":"bug","color":"d73a4a"},{"name":"core","color":"0e8a16"}],
         "assignees":[{"login":"octocat"}],"comments":[{"body":"a"},{"body":"b"},{"body":"c"}]}
        """#
        let p = try XCTUnwrap(LinkPreview.parseIssue(Data(json.utf8)))
        XCTAssertEqual(p.title, "Members can't change roles")
        XCTAssertEqual(p.labels.map(\.name), ["bug", "core"])
        XCTAssertEqual(p.labels.first?.color, "d73a4a")
        XCTAssertEqual(p.assignees, ["octocat"])
        XCTAssertEqual(p.comments, 3)
        XCTAssertTrue(p.final)
        XCTAssertNil(p.additions)
    }

    func testGarbage() {
        XCTAssertNil(LinkPreview.parsePullRequest(Data("nope".utf8)))
        XCTAssertNil(LinkPreview.parseIssue(Data("{}".utf8)), "no title, no preview")
    }

    // Caching

    func testRefreshSchedule() {
        XCTAssertTrue(LinkPreview.needsRefresh(final: false, age: nil), "never fetched")
        XCTAssertFalse(LinkPreview.needsRefresh(final: false, age: 30))
        XCTAssertTrue(LinkPreview.needsRefresh(final: false, age: 61))
        XCTAssertFalse(LinkPreview.needsRefresh(final: true, age: 99_999), "merged or closed: kept for good")
    }
}
