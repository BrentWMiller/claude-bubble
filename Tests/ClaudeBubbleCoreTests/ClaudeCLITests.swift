import XCTest
@testable import ClaudeBubbleCore

final class ClaudeCLITests: XCTestCase {
    func testSummaryArgumentsAreHookFreeAndUnsaved() {
        XCTAssertEqual(ClaudeCLI.summaryArguments, ["-p", "--model", "claude-haiku-5-5", "--no-session-persistence",
                                                    "--tools", "", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"])
    }

    func testLocatePrefersLocalBin() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(ClaudeCLI.locate(home: home, isExecutable: { $0 == "/Users/x/.local/bin/claude" || $0 == "/opt/homebrew/bin/claude" }),
                       "/Users/x/.local/bin/claude")
        XCTAssertEqual(ClaudeCLI.locate(home: home, isExecutable: { $0 == "/Users/x/.claude/local/claude" }), "/Users/x/.claude/local/claude")
        XCTAssertNil(ClaudeCLI.locate(home: home, isExecutable: { _ in false }))
    }

    func testOutputReadsStdoutGivenStdin() {
        XCTAssertEqual(ProcessRun.output(executable: "/bin/cat", arguments: [], input: "hello\n", timeout: 5), "hello")
    }

    func testFailureAndTimeoutFallBack() {
        XCTAssertNil(ProcessRun.output(executable: "/usr/bin/false", arguments: [], input: "", timeout: 5))
        XCTAssertNil(ProcessRun.output(executable: "/nonexistent/claude", arguments: [], input: "", timeout: 5))
        let start = Date()
        XCTAssertNil(ProcessRun.output(executable: "/bin/sleep", arguments: ["10"], input: "", timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testTimeoutStopsAProcessThatIgnoresTerm() {
        let start = Date()
        XCTAssertNil(ProcessRun.output(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 20"], input: "", timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }
}
