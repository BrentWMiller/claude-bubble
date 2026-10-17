import XCTest
@testable import ClaudeBubbleCore

final class DefaultsMigrationTests: XCTestCase {
    // Fixed names, emptied around each test (a fresh name per test would leave a plist behind every run).
    let old = "claude-bubble-tests-legacy", new = "claude-bubble-tests-current"

    override func setUp() { clear() }
    override func tearDown() { clear() }
    func clear() { for n in [old, new] { UserDefaults(suiteName: n)!.removePersistentDomain(forName: n) } }

    func testCopiesTheOldSettingsOnce() {
        UserDefaults(suiteName: old)!.setPersistentDomain(["diameter": 90.0, "bubbleHidden": true], forName: old)
        let target = UserDefaults(suiteName: new)!
        XCTAssertTrue(DefaultsMigration.migrate(from: old, to: new, in: target))
        XCTAssertEqual(target.double(forKey: "diameter"), 90)
        XCTAssertTrue(target.bool(forKey: "bubbleHidden"))
        target.set(72.0, forKey: "diameter")
        XCTAssertFalse(DefaultsMigration.migrate(from: old, to: new, in: target), "only once")
        XCTAssertEqual(target.double(forKey: "diameter"), 72, "later changes stick")
    }

    func testLeavesExistingSettingsAlone() {
        UserDefaults(suiteName: old)!.setPersistentDomain(["diameter": 90.0], forName: old)
        let target = UserDefaults(suiteName: new)!
        target.set(60.0, forKey: "diameter")
        XCTAssertFalse(DefaultsMigration.migrate(from: old, to: new, in: target))
        XCTAssertEqual(target.double(forKey: "diameter"), 60)
    }

    func testNothingToMigrate() {
        XCTAssertFalse(DefaultsMigration.migrate(from: old, to: new, in: UserDefaults(suiteName: new)!))
    }
}
