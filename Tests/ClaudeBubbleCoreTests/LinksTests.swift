import XCTest
@testable import ClaudeBubbleCore

final class LinksTests: XCTestCase {
    // Branch names

    func testIssueFromBranch() {
        XCTAssertEqual(LinkFinder.issue(fromBranch: "team/issue-7211"), 7211)
        XCTAssertEqual(LinkFinder.issue(fromBranch: "issue_42-login"), 42)
        XCTAssertEqual(LinkFinder.issue(fromBranch: "fix/7211"), 7211)
        XCTAssertEqual(LinkFinder.issue(fromBranch: "7211-add-roles"), 7211)
        XCTAssertEqual(LinkFinder.issue(fromBranch: "feat/7211-team-form"), 7211)
        XCTAssertEqual(LinkFinder.issue(fromBranch: "GH-88"), 88)
        XCTAssertNil(LinkFinder.issue(fromBranch: "main"))
        XCTAssertNil(LinkFinder.issue(fromBranch: "release-v2"))
        XCTAssertNil(LinkFinder.issue(fromBranch: "feat/oauth2-login"))
    }

    // Remotes

    func testRepoFromRemote() {
        XCTAssertEqual(LinkFinder.repo(fromRemote: "git@github.com:acme/widgets.git"), "acme/widgets")
        XCTAssertEqual(LinkFinder.repo(fromRemote: "https://github.com/octocat/hello-world.git"), "octocat/hello-world")
        XCTAssertEqual(LinkFinder.repo(fromRemote: "https://github.com/o/r"), "o/r")
        XCTAssertNil(LinkFinder.repo(fromRemote: "git@gitlab.com:o/r.git"))
    }

    // Conversation text

    func testIssuesInText() {
        let text = """
        Looking at https://github.com/acme/widgets/issues/7211 first. This is related to issue #7180,
        and PR https://github.com/acme/widgets/pull/7213 (not an issue). Fixes #7190. Also see #12 later.
        Again https://github.com/acme/widgets/issues/7211.
        """
        let found = LinkFinder.issues(inText: text, repo: "acme/widgets")
        XCTAssertEqual(found.map(\.number), [7211, 7180, 7190], "URLs, 'issue #n' and 'fixes #n', each once, not PRs or bare #n")
        XCTAssertEqual(found.first?.repo, "acme/widgets")
    }

    func testBareMentionsNeedARepo() {
        XCTAssertEqual(LinkFinder.issues(inText: "see issue #7180", repo: nil).count, 0)
        XCTAssertEqual(LinkFinder.issues(inText: "https://github.com/a/b/issues/5", repo: nil).map(\.repo), ["a/b"])
    }

    func testIssueLinkPointsAtGitHub() {
        let link = LinkFinder.issueLink(repo: "acme/widgets", number: 7211)
        XCTAssertEqual(link.kind, .issue)
        XCTAssertEqual(link.label, "#7211")
        XCTAssertEqual(link.url.absoluteString, "https://github.com/acme/widgets/issues/7211")
    }

    // Putting them together

    func testMergeOrdersAndCaps() {
        let pr = SessionLink(kind: .pr, label: "#7213", url: URL(string: "https://github.com/o/r/pull/7213")!)
        let art = SessionLink(kind: .artifact, label: "Roll history", url: URL(string: "https://claude.ai/artifact/x")!)
        let merged = SessionLinks.merge(job: [art, pr], branchIssue: 7211, mentioned: [7211, 7180, 7190, 7191], repo: "o/r")
        XCTAssertEqual(merged.map(\.label), ["#7211", "#7191", "#7213", "Roll history"], "branch issue, latest mention, PRs, artifacts")
        XCTAssertLessThanOrEqual(merged.count, SessionLinks.maxShown)
        XCTAssertEqual(SessionLinks.merge(job: [], branchIssue: nil, mentioned: [5], repo: nil), [], "no repo, no issue link")
    }

    // Job file

    func testJobLinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sid = "6d862ee9-15fc-42aa-bcef-b79d03c0d017"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("6d862ee9"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ##"{"sessionId":"\##(sid)","children":[{"id":"7213","href":"https://github.com/o/r/pull/7213","kind":"pr"},{"id":"a.html","href":"https://claude.ai/artifact/X","kind":"frame","title":"Roll Change History"}]}"##
            .write(to: dir.appendingPathComponent("6d862ee9/state.json"), atomically: true, encoding: .utf8)
        let job = try XCTUnwrap(JobStore.load(sessionId: sid, from: dir))
        XCTAssertTrue(job.hasPullRequest)
        XCTAssertEqual(job.links.map(\.kind), [.pr, .artifact])
        XCTAssertEqual(job.links.map(\.label), ["#7213", "Roll Change History"])
    }
}
