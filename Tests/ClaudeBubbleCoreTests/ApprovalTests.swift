import Darwin
import XCTest
@testable import HookCore

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
        XCTAssertEqual(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true }), .allow)
        wait(for: [served], timeout: 5)
    }

    func testDeny() throws {
        let served = try serve { ApprovalReply(id: $0.id, behavior: .deny) }
        XCTAssertEqual(request().ask(socketPath: path, deadline: Date() + 5, stillWaiting: { true }), .deny)
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
