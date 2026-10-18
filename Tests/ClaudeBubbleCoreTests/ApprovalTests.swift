import Darwin
import XCTest
@testable import HookCore
import ClaudeBubbleCore

final class ApprovalTests: XCTestCase {
    var path: String!

    override func setUp() {
        // Short: a socket path must fit in 104 bytes.
        path = "/tmp/cb-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() { unlink(path) }

    func input(_ tool: String = "Bash", _ toolInput: [String: Any] = ["command": "rm -rf build"],
               event: String = "PermissionRequest") -> [String: Any] {
        ["hook_event_name": event, "session_id": "s1", "cwd": "/repo", "tool_name": tool, "tool_input": toolInput]
    }

    // The request

    func testRequestForAPermissionRequest() throws {
        let r = try XCTUnwrap(ApprovalRequest.make(input(), id: "r1"))
        XCTAssertEqual(r, ApprovalRequest(id: "r1", session: "s1", tool: "Bash", detail: "rm -rf build", cwd: "/repo"))
    }

    func testNoRequestForOtherEvents() {
        XCTAssertNil(ApprovalRequest.make(input(event: "PreToolUse"), id: "r1"))
        XCTAssertNil(ApprovalRequest.make(input(event: "Notification"), id: "r1"))
    }

    func testDetailShowsWhatIsBeingApproved() {
        XCTAssertEqual(Approval.detail(tool: "Write", input: ["file_path": "/a/b.swift", "content": "x"]), "/a/b.swift")
        XCTAssertEqual(Approval.detail(tool: "WebFetch", input: ["url": "https://x.dev", "prompt": "p"]), "https://x.dev")
        XCTAssertEqual(Approval.detail(tool: "mcp__x__y", input: ["b": 2, "a": "1"]), #"{"a":"1","b":2}"#)
        let long = String(repeating: "x", count: Approval.maxDetail + 50)
        XCTAssertEqual(Approval.detail(tool: "Bash", input: ["command": long]).count, Approval.maxDetail + 1, "capped")
    }

    // The hook's output

    func testOutput() throws {
        let allow = try XCTUnwrap(JSONSerialization.jsonObject(with: Approval.output(.allow)) as? [String: Any])
        let specific = try XCTUnwrap(allow["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((specific["decision"] as? [String: Any])?["behavior"] as? String, "allow")
        let deny = try XCTUnwrap(JSONSerialization.jsonObject(with: Approval.output(.deny)) as? [String: Any])
        let decision = (deny["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "deny")
        XCTAssertNotNil(decision?["message"], "tells Claude why")
    }

    func testStillWaitingOnlyWhileTheSessionNeedsYou() {
        XCTAssertTrue(Approval.stillWaiting(record: ["state": "needs"]))
        XCTAssertFalse(Approval.stillWaiting(record: ["state": "working"]))
        XCTAssertFalse(Approval.stillWaiting(record: nil), "session gone")
    }

    // Over the socket

    /// A one-shot app: accepts one connection, hands its request to `respond`, and sends back what it returns.
    func serve(_ respond: @escaping (ApprovalRequest) -> ApprovalReply?) throws -> XCTestExpectation {
        let server = try XCTUnwrap(UnixSocket.listen(path))
        let served = expectation(description: "served")
        DispatchQueue.global().async {
            let fd = accept(server, nil, nil)
            XCTAssertTrue(UnixSocket.peerIsSelf(fd))
            if let line = UnixSocket.readLine(fd, deadline: Date() + 5),
               let request = try? JSONDecoder().decode(ApprovalRequest.self, from: line),
               let reply = respond(request) {
                UnixSocket.write(fd, Approval.line(reply))
            }
            close(fd)
            close(server)
            served.fulfill()
        }
        return served
    }

    func request() -> ApprovalRequest { ApprovalRequest.make(input(), id: "r1")! }

    func testTheAppsAnswerComesBack() throws {
        let served = try serve { ApprovalReply(id: $0.id, behavior: .allow) }
        XCTAssertEqual(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true })?.behavior, .allow)
        wait(for: [served], timeout: 5)
    }

    func testDeny() throws {
        let served = try serve { ApprovalReply(id: $0.id, behavior: .deny) }
        XCTAssertEqual(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true })?.behavior, .deny)
        wait(for: [served], timeout: 5)
    }

    func testAReplyForAnotherRequestIsIgnored() throws {
        let served = try serve { _ in ApprovalReply(id: "other", behavior: .allow) }
        XCTAssertNil(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true }))
        wait(for: [served], timeout: 5)
    }

    func testNoAppMeansNoDecisionAndNoWait() {
        let start = Date()
        XCTAssertNil(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true }))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testTheAppClosingMeansNoDecision() throws {
        let served = try serve { _ in nil }
        XCTAssertNil(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true }))
        wait(for: [served], timeout: 5)
    }

    func testAnsweredInTheTerminalStopsWaiting() throws {
        let server = try XCTUnwrap(UnixSocket.listen(path))
        defer { close(server) }
        var checks = 0
        let start = Date()
        XCTAssertNil(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { checks += 1; return checks < 2 }))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testGivesUpAtTheDeadline() throws {
        let server = try XCTUnwrap(UnixSocket.listen(path))
        defer { close(server) }
        let start = Date()
        XCTAssertNil(request().ask(socketPath: path, deadline: Date() + 0.4, stillWaiting: { true }))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testTheSocketIsPrivate() throws {
        let server = try XCTUnwrap(UnixSocket.listen(path))
        defer { close(server) }
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }
}

final class ApprovalCardTests: XCTestCase {
    func make(_ tool: String, _ toolInput: [String: Any], cwd: String = "/repo", file: String? = nil) -> ApprovalRequest {
        ApprovalRequest.make(["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": cwd, "tool_name": tool,
                              "tool_input": toolInput], id: "r", readFile: { _ in file })!
    }

    func testBashCarriesItsReason() {
        let r = make("Bash", ["command": "npm test -- hooks/", "description": "Run the hook tests"])
        XCTAssertEqual(r.reason, "Run the hook tests")
        XCTAssertEqual(r.headline, "Wants to run a command")
        XCTAssertEqual(r.blockLabel, "BASH")
        XCTAssertEqual(r.allowTitle, "Allow")
        XCTAssertNil(r.diff)
        XCTAssertNil(make("WebFetch", ["url": "https://x", "description": "?"]).reason, "only Bash's description is a reason")
    }

    func testEditDiffWithContextFromTheFile() throws {
        let file = "a\nconst req = await read(event)\nreturn wait(req)\nz"
        let r = make("Edit", ["file_path": "/repo/src/hooks/permission.ts", "old_string": "return wait(req)",
                              "new_string": "if (req.resolved) return req\nreturn wait(req, { timeout })"], file: file)
        XCTAssertEqual(r.headline, "Wants to edit a file")
        XCTAssertEqual(r.allowTitle, "Allow edit")
        XCTAssertEqual(r.blockLabel, "src/hooks/permission.ts")
        let diff = try XCTUnwrap(r.diff)
        XCTAssertEqual(diff.lines, [.init(kind: .context, text: "const req = await read(event)"),
                                    .init(kind: .removed, text: "return wait(req)"),
                                    .init(kind: .added, text: "if (req.resolved) return req"),
                                    .init(kind: .added, text: "return wait(req, { timeout })")])
        XCTAssertEqual(diff.added, 2)
        XCTAssertEqual(diff.removed, 1)
    }

    func testUnchangedEndsAreContextNotChanges() {
        let diff = ApprovalDiff([ApprovalEdit(old: "a\nb\nc", new: "a\nB\nc")])
        XCTAssertEqual(diff.lines, [.init(kind: .context, text: "a"), .init(kind: .removed, text: "b"), .init(kind: .added, text: "B")])
        XCTAssertEqual(diff.added, 1)
        XCTAssertEqual(diff.removed, 1)
    }

    func testWriteIsAllAdded() throws {
        let r = make("Write", ["file_path": "/repo/new.txt", "content": "1\n2\n3\n4\n5\n6\n7\n8"])
        XCTAssertEqual(r.allowTitle, "Allow write")
        let diff = try XCTUnwrap(r.diff)
        XCTAssertEqual(diff.lines.count, ApprovalDiff.maxLines)
        XCTAssertEqual(diff.hidden, 2)
        XCTAssertEqual(diff.added, 8)
        XCTAssertEqual(diff.removed, 0)
    }

    func testMultiEdit() throws {
        let r = make("MultiEdit", ["file_path": "/repo/a", "edits": [["old_string": "x", "new_string": "y"],
                                                                     ["old_string": "p", "new_string": "q"]]])
        XCTAssertEqual(try XCTUnwrap(r.diff).added, 2)
    }

    func testLineAbove() {
        XCTAssertEqual(ApprovalEdit.line(above: "c", in: "a\nb\nc"), "b")
        XCTAssertNil(ApprovalEdit.line(above: "a", in: "a\nb"), "first line: nothing above")
        XCTAssertNil(ApprovalEdit.line(above: "q", in: "a\nb"), "not found")
    }

    func testMCPHeadline() {
        XCTAssertEqual(make("mcp__github__create_issue", [:]).headline, "Wants to use github's create_issue")
        XCTAssertEqual(make("mcp__github__create_issue", [:]).blockLabel, "MCP")
    }

    func testOlderRequestsWithoutTheNewFieldsDecode() throws {
        let json = #"{"id":"r","session":"s","tool":"Bash","detail":"ls","cwd":"/"}"#
        let r = try JSONDecoder().decode(ApprovalRequest.self, from: Data(json.utf8))
        XCTAssertNil(r.reason)
        XCTAssertNil(r.edits)
    }

    // Measurements

    func testWrapEstimate() {
        XCTAssertEqual(ApprovalCardLayout.lines("short", width: 266, glyph: 6.65, limit: 3), 1)
        XCTAssertEqual(ApprovalCardLayout.lines(String(repeating: "x", count: 50), width: 266, glyph: 6.65, limit: 3), 2)
        XCTAssertEqual(ApprovalCardLayout.lines("a\nb\nc\nd", width: 266, glyph: 6.65, limit: 3), 3, "capped")
    }

    func testHeights() {
        let bash = make("Bash", ["command": "ls"])
        let one: Double = 24 + 15 + 14 + 8 + 30
        XCTAssertEqual(ApprovalCardLayout.height(bash, width: 290), one)
        let reasoned = make("Bash", ["command": "ls", "description": "List files"])
        XCTAssertEqual(ApprovalCardLayout.height(reasoned, width: 290), ApprovalCardLayout.height(bash, width: 290) + 16 + 8)
        let write = make("Write", ["file_path": "/repo/n", "content": "1\n2\n3\n4\n5\n6\n7"])
        let diff: Double = 24 + 6 * 17 + 8 + 16 + 8 + 30
        XCTAssertEqual(ApprovalCardLayout.height(write, width: 290), diff)
        XCTAssertLessThanOrEqual(ApprovalCardLayout.height(write, width: 290), ApprovalCardLayout.maxHeight)
    }

    func testTheIslandWindowHasRoomForTheTallestCard() {
        XCTAssertLessThanOrEqual(ApprovalCardLayout.maxHeight, Double(IslandLayout.maxApprovalHeight))
    }
}

final class QuestionCardTests: XCTestCase {
    let toolInput: [String: Any] = ["questions": [
        ["question": "How should the island be resized?", "header": "Resize how", "multiSelect": false,
         "options": [["label": "Width slider", "description": "A slider"], ["label": "Drag its ends", "description": "Drag"]]],
        ["question": "Which widths?", "header": "Applies to", "multiSelect": true,
         "options": [["label": "Resting bar"], ["label": "Hover panel"], ["label": "Cards"]]],
    ]]

    func request(_ input: [String: Any]? = nil) -> ApprovalRequest {
        ApprovalRequest.make(["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/", "tool_name": "AskUserQuestion",
                              "tool_input": input ?? toolInput], id: "r")!
    }

    func testQuestionsAreParsed() throws {
        let r = request()
        let qs = try XCTUnwrap(r.questions)
        XCTAssertEqual(qs.count, 2)
        XCTAssertEqual(qs[0].header, "Resize how")
        XCTAssertEqual(qs[0].options.map(\.label), ["Width slider", "Drag its ends"])
        XCTAssertEqual(qs[0].options[0].description, "A slider")
        XCTAssertTrue(qs[1].multiSelect)
        XCTAssertEqual(r.headline, "Has 2 questions")
    }

    func testQuestionsWithoutOptionsStayInTheTerminal() {
        func make(_ input: [String: Any]) -> ApprovalRequest? {
            ApprovalRequest.make(["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/",
                                  "tool_name": "AskUserQuestion", "tool_input": input], id: "r")
        }
        XCTAssertNil(make(["questions": [["question": "Name?"]]]), "no options: the hook doesn't offer it")
        XCTAssertNil(make(["questions": [["question": "Pick", "options": (1...5).map { ["label": "\($0)"] }]]]),
                     "more options than the card shows")
    }

    func testAnsweringPassesTheQuestionsBackWithTheAnswers() throws {
        let reply = ApprovalReply(id: "r", behavior: .allow,
                                  answers: ["How should the island be resized?": "Width slider", "Which widths?": "Resting bar, Cards"])
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Approval.output(reply, tool: "AskUserQuestion", toolInput: toolInput)) as? [String: Any])
        let decision = try XCTUnwrap((out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updated = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["questions"] as? [Any])?.count, 2, "the questions go back unchanged")
        XCTAssertEqual(updated["answers"] as? [String: String], reply.answers)
    }

    func testPlanApprovalPassesThePlanBack() throws {
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Approval.output(ApprovalReply(id: "r", behavior: .allow),
                                                                                   tool: "ExitPlanMode", toolInput: ["plan": "1. Do it"])) as? [String: Any])
        let decision = (out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual((decision?["updatedInput"] as? [String: Any])?["plan"] as? String, "1. Do it")
    }

    func testOrdinaryToolsDontEchoTheirInput() throws {
        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Approval.output(ApprovalReply(id: "r", behavior: .allow),
                                                                                   tool: "Bash", toolInput: ["command": "ls"])) as? [String: Any])
        let decision = (out["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertNil(decision?["updatedInput"])
    }

    func testDenyingAPlanKeepsPlanning() {
        let r = ApprovalRequest.make(["hook_event_name": "PermissionRequest", "session_id": "s", "cwd": "/", "tool_name": "ExitPlanMode",
                                      "tool_input": ["plan": "1. Do it"]], id: "r")!
        XCTAssertEqual(r.headline, "Wants to start on the plan")
        XCTAssertEqual(r.allowTitle, "Approve plan")
        XCTAssertEqual(r.denyTitle, "Keep planning")
        XCTAssertEqual(r.detail, "1. Do it")
        XCTAssertEqual(r.blockLabel, "PLAN")
    }

    func testQuestionCardHeight() {
        let r = request()
        // Step line, one line of question (the longest), three options (the most), the buttons.
        let expected: Double = 16 + 8 + 16 + 8 + (3 * 26 + 2 * 4) + 8 + 30
        XCTAssertEqual(ApprovalCardLayout.height(r, width: 290), expected)
        XCTAssertLessThanOrEqual(ApprovalCardLayout.height(r, width: 290), ApprovalCardLayout.maxHeight)
    }
}
