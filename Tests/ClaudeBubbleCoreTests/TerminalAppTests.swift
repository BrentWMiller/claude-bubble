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

    // The session's own app

    /// claude (900) → zsh (800) → login (700) → Ghostty (600) → launchd (1)
    let tree: [Int32: Int32] = [900: 800, 800: 700, 700: 600, 600: 1]

    func testWalksUpToTheAppTheSessionRunsIn() {
        XCTAssertEqual(TerminalApp.owningApp(of: 900, parent: { self.tree[$0] }, isApp: { $0 == 600 }), 600)
    }

    func testSkipsHelperAppsOnTheWay() {
        // An editor's terminal: claude → zsh → "Code Helper" (an app, but not a regular one) → Code.
        let editor: [Int32: Int32] = [50: 40, 40: 30, 30: 20, 20: 1]
        XCTAssertEqual(TerminalApp.owningApp(of: 50, parent: { editor[$0] }, isApp: { $0 == 20 }), 20)
    }

    func testNoAppAboveIt() {
        // tmux or ssh: the chain ends at launchd without an app.
        XCTAssertNil(TerminalApp.owningApp(of: 900, parent: { self.tree[$0] }, isApp: { _ in false }))
        XCTAssertNil(TerminalApp.owningApp(of: 900, parent: { _ in nil }, isApp: { _ in false }))
    }

    func testStopsOnALoop() {
        XCTAssertNil(TerminalApp.owningApp(of: 5, parent: { $0 == 5 ? 6 : 5 }, isApp: { _ in false }))
    }

    func testWhichSessionAClickMeans() {
        let now = Date()
        func s(_ id: String, _ state: BubbleState, ago: Double, pid: Int32? = 10) -> Session {
            Session(id: id, state: state, updatedAt: now, stateSince: now.addingTimeInterval(-ago), pid: pid)
        }
        XCTAssertEqual(TerminalApp.target(in: [s("a", .working, ago: 1), s("b", .needs, ago: 50)])?.id, "b", "needs you first")
        XCTAssertEqual(TerminalApp.target(in: [s("a", .idle, ago: 100), s("b", .working, ago: 5)])?.id, "b")
        XCTAssertEqual(TerminalApp.target(in: [s("a", .needs, ago: 1, pid: nil), s("b", .working, ago: 5)])?.id, "b",
                       "one we can't trace is skipped")
        XCTAssertNil(TerminalApp.target(in: []))
    }

    func testFallbackLooksWhereClaudeCodeIsOpen() {
        let procs: [(pid: Int32, args: [String])] = [
            (19657, ["/Users/x/.local/bin/claude", "--chrome-native-host"]),          // a browser extension's helper
            (48363, ["/Users/x/.local/bin/claude", "daemon", "run"]),                 // the background daemon
            (48535, ["/x/ClaudeCode.app/Contents/MacOS/claude", "--bg-pty-host", "/tmp/s.sock"]),
            (60694, ["claude bg-spare"]),
            (79193, ["claude"]),                                                     // an interactive session
            (52467, ["/Users/x/.local/bin/claude", "agents", "--inherit-permission-mode", "auto"]),
            (81000, ["claude", "--resume", "abc"]),
        ]
        XCTAssertEqual(TerminalApp.fallbackOrder(procs), [52467, 81000, 79193],
                       "the agents view first, then interactive sessions newest first; never helpers, the daemon or hosts")
    }
}
