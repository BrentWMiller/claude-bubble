import XCTest
@testable import ClaudeBubbleCore

final class TerminalAppTests: XCTestCase {
    func testPrefersHyperWhenInstalled() {
        let installed: Set = ["com.apple.Terminal", "co.zeit.hyper"]
        XCTAssertEqual(TerminalApp.resolve(override: nil, isInstalled: installed.contains), "co.zeit.hyper")
    }

    func testOverrideWinsWhenInstalled() {
        let installed: Set = ["co.zeit.hyper", "com.googlecode.iterm2"]
        XCTAssertEqual(TerminalApp.resolve(override: "com.googlecode.iterm2", isInstalled: installed.contains), "com.googlecode.iterm2")
    }

    func testMissingOverrideFallsBackToTheList() {
        let installed: Set = ["com.apple.Terminal"]
        XCTAssertEqual(TerminalApp.resolve(override: "com.example.gone", isInstalled: installed.contains), "com.apple.Terminal")
    }

    func testNothingInstalledIsNil() {
        XCTAssertNil(TerminalApp.resolve(override: nil, isInstalled: { _ in false }))
    }
}
