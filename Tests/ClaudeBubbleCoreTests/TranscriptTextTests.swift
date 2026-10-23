import XCTest
@testable import ClaudeBubbleCore

final class TranscriptTextTests: XCTestCase {
    func testKeepsUserAndClaudeTextOnly() {
        let jsonl = """
        {"type":"user","message":{"content":"fix the login test"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}
        {"type":"user","isMeta":true,"message":{"content":"meta"}}
        {"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}
        not json
        {"type":"user","message":{"content":"<command-name>/copy</command-name>"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it. Tests pass."}]}}
        """
        XCTAssertEqual(TranscriptText.turns(fromJSONL: Data(jsonl.utf8)),
                       [TranscriptTurn(fromUser: true, text: "fix the login test"),
                        TranscriptTurn(fromUser: false, text: "Fixed it. Tests pass.")])
    }

    func testPlainLineIsFirstSentenceWithoutMarkup() {
        let turns = [TranscriptTurn(fromUser: false, text: "Here's a version:\n```\ncode\n```\n**OAuth** works now. More.")]
        XCTAssertEqual(TranscriptText.plainLine(turns), "Here's a version: OAuth works now.")
    }

    func testPlainLineCapsAt140() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(TranscriptText.plainLine([TranscriptTurn(fromUser: false, text: long)])?.count, 140)
    }

    func testPlainLineIsNilWithoutClaudeText() {
        XCTAssertNil(TranscriptText.plainLine([TranscriptTurn(fromUser: true, text: "hi")]))
    }

    func testOffsetPastEndReadsTail() {
        XCTAssertEqual(TranscriptText.readStart(offset: 5_000_000, fileSize: 3_000_000), 1_000_000)
        XCTAssertEqual(TranscriptText.readStart(offset: 5_000_000, fileSize: 100), 0)
        XCTAssertEqual(TranscriptText.readStart(offset: 0, fileSize: 3_000_000), 1_000_000)
        XCTAssertEqual(TranscriptText.readStart(offset: 500, fileSize: 3_000_000), 500)
    }

    func testSummaryInputStartsWithPromptAndLabelsTurns() {
        let s = TranscriptText.summaryInput([TranscriptTurn(fromUser: true, text: "go"), TranscriptTurn(fromUser: false, text: "done")])
        XCTAssertTrue(s.hasPrefix(TranscriptText.summaryPrompt + "\n\n"))
        XCTAssertTrue(s.hasSuffix("YOU: go\n\nCLAUDE: done"))
        XCTAssertEqual(TranscriptText.summaryPrompt, "Below is the recent part of a Claude Code session. In one or two short sentences, at most 140 characters, say what the session got done or where it stands, and whether it needs the user. No preamble.")
    }
}
