import XCTest
@testable import ClaudeBubbleCore

final class SessionInboxTests: XCTestCase {
    let sid = "c10500c7-26b2-439f-9e19-88dac0e46d13"
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func register(pid: Int32, session: String, socket: String = "/tmp/cc-socks/1.sock", proto: Int = 1) throws {
        try write("\(pid).json", """
        {"pid":\(pid),"sessionId":"\(session)","messagingSocketPath":"\(socket)","peerProtocol":\(proto),"status":"idle"}
        """)
    }

    func testFindsSessionByPidWithItsToken() throws {
        try register(pid: 11010, session: sid, socket: "/tmp/cc-socks/11010.sock")
        try write("11010.abcdef.key", #"{"peerToken":"tok123","procStart":"x","pidDomain":"darwin"}"#)
        XCTAssertEqual(SessionInbox.peer(sessionId: sid, pid: 11010, in: dir),
                       InboxPeer(socketPath: "/tmp/cc-socks/11010.sock", token: "tok123"))
    }

    func testFindsSessionRegisteredUnderAnotherProcess() throws {
        try register(pid: 200, session: "someone-else")
        try register(pid: 300, session: sid, socket: "/tmp/cc-socks/300.sock")
        XCTAssertEqual(SessionInbox.peer(sessionId: sid, pid: 999, in: dir)?.socketPath, "/tmp/cc-socks/300.sock")
    }

    func testAnotherProcessesKeyIsNotUsed() throws {
        try register(pid: 30, session: sid)
        try write("300.abc.key", #"{"peerToken":"not-mine"}"#)
        XCTAssertNil(SessionInbox.peer(sessionId: sid, pid: 30, in: dir)?.token)
    }

    func testNoInboxForUnknownSessionOrOtherProtocol() throws {
        XCTAssertNil(SessionInbox.peer(sessionId: sid, pid: 1, in: dir))
        try register(pid: 5, session: sid, proto: 2)
        XCTAssertNil(SessionInbox.peer(sessionId: sid, pid: 5, in: dir))
        try write("6.json", "not json")
        XCTAssertNil(SessionInbox.peer(sessionId: sid, pid: 6, in: dir))
    }

    func testPayloadIsAuthThenPlainStringMessage() throws {
        let lines = String(decoding: SessionInbox.payload("hi \"there\"\nok", token: "t"), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let auth = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String]
        XCTAssertEqual(auth, ["type": "auth", "token": "t"])
        let msg = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        XCTAssertEqual(msg?["type"] as? String, "user")
        let message = msg?["message"] as? [String: String]
        XCTAssertEqual(message, ["role": "user", "content": "hi \"there\"\nok"])
    }

    func testPayloadWithoutTokenHasNoAuthLine() {
        let text = String(decoding: SessionInbox.payload("x", token: nil), as: UTF8.self)
        XCTAssertFalse(text.contains("auth"))
        XCTAssertEqual(text.filter { $0 == "\n" }.count, 1)
    }

    func testSpokenSaysWhoItsFromAndSkipsSilence() {
        XCTAssertNil(SessionInbox.spoken("  \n"))
        let m = SessionInbox.spoken(" run the tests ")!
        XCTAssertTrue(m.contains("from the user"))
        XCTAssertTrue(m.hasSuffix("run the tests"))
    }

    func testDroppedListsFilesThenText() {
        XCTAssertNil(SessionInbox.dropped(files: [], texts: [" "]))
        let m = SessionInbox.dropped(files: [URL(fileURLWithPath: "/a/b.png"), URL(fileURLWithPath: "/c d.txt")],
                                     texts: ["look here"])!
        XCTAssertTrue(m.contains("- /a/b.png\n- /c d.txt"))
        XCTAssertTrue(m.hasSuffix("look here"))
    }

    func testStageWritesAndPruneClearsOldDrops() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(SessionInbox.stage(Data("png".utf8), ext: "png", at: now, in: dir))
        XCTAssertTrue(url.lastPathComponent.hasPrefix("drop-") && url.pathExtension == "png")
        XCTAssertEqual(try Data(contentsOf: url), Data("png".utf8))
        let keep = try XCTUnwrap(SessionInbox.stage(Data("new".utf8), ext: "txt", at: now.addingTimeInterval(1), in: dir))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 24 * 3600)], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: keep.path)
        SessionInbox.pruneDrops(now: now, in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }
}
