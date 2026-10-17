import XCTest
@testable import ClaudeBubbleCore

final class IngestTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ text: String) throws {
        // Atomically, like the hook: a new file renamed over the old one.
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // FileCache
    func testCacheDecodesOnceUntilTheFileChanges() throws {
        try write("a.json", "one")
        let cache = FileCache<String>()
        var decodes = 0
        let decode: (Data) -> String? = { decodes += 1; return String(decoding: $0, as: UTF8.self) }
        let url = dir.appendingPathComponent("a.json")
        XCTAssertEqual(cache.value(at: url, decode: decode), "one")
        XCTAssertEqual(cache.value(at: url, decode: decode), "one")
        XCTAssertEqual(decodes, 1)
        try write("a.json", "two")
        XCTAssertEqual(cache.value(at: url, decode: decode), "two")
        XCTAssertEqual(decodes, 2)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(cache.value(at: url, decode: decode))
    }

    func testCacheRemembersUnreadableFilesToo() throws {
        try write("bad.json", "{nope")
        let cache = FileCache<Int>()
        var decodes = 0
        let url = dir.appendingPathComponent("bad.json")
        XCTAssertNil(cache.value(at: url) { _ in decodes += 1; return nil })
        XCTAssertNil(cache.value(at: url) { _ in decodes += 1; return nil })
        XCTAssertEqual(decodes, 1)
    }

    func testLoadWithACacheMatchesLoadWithout() throws {
        let t = Date().timeIntervalSince1970
        try write("s1.json", #"{"state":"working","cwd":"/x","updated_at":\#(t),"detail":"Reading files"}"#)
        try write("s2.json", #"{"state":"needs","cwd":"/y","updated_at":\#(t)}"#)
        let cache = SessionStore.LoadCache()
        let plain = SessionStore.load(from: dir, isAlive: { _, _ in true })
        XCTAssertEqual(SessionStore.load(from: dir, isAlive: { _, _ in true }, cache: cache), plain)
        XCTAssertEqual(SessionStore.load(from: dir, isAlive: { _, _ in true }, cache: cache), plain)
        try write("s2.json", #"{"state":"idle","cwd":"/y","updated_at":\#(t)}"#)
        XCTAssertEqual(SessionStore.load(from: dir, isAlive: { _, _ in true }, cache: cache).first { $0.id == "s2" }?.state, .idle)
    }

    // SessionWatcher
    func testWatcherCoalescesABurstOffTheMainThread() throws {
        let t = Date().timeIntervalSince1970
        var calls = 0
        let delivered = expectation(description: "delivered")
        delivered.assertForOverFulfill = false
        let watcher = SessionWatcher(directory: dir, coalesce: 0.1) { _, sessions in
            XCTAssertTrue(Thread.isMainThread)
            calls += 1
            if sessions.count == 20 { delivered.fulfill() }
        }
        watcher.start()
        for i in 0..<20 { try write("s\(i).json", #"{"state":"working","updated_at":\#(t)}"#) }
        wait(for: [delivered], timeout: 3)
        XCTAssertLessThanOrEqual(calls, 4, "20 writes in a burst should come through as a few reloads, not 20+")
        watcher.stop()
    }
}
