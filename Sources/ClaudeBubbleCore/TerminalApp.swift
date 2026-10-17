import Foundation

/// Which app a click brings forward: the one the session is actually running in (found by walking up from its
/// `claude` process to the first app: Terminal, iTerm, Ghostty, Warp, Kitty, an editor's terminal, …), or, when
/// that can't be traced (tmux, ssh), the first installed terminal from `candidates`.
public enum TerminalApp {
    /// Override with: defaults write dev.claudebubble.app terminalBundleID <bundle id>
    public static let overrideKey = "terminalBundleID"

    public static let candidates = [
        "co.zeit.hyper",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal"
    ]

    public static func resolve(override: String?, isInstalled: (String) -> Bool) -> String? {
        ([override].compactMap { $0 } + candidates).first(where: isInstalled)
    }

    /// The first ancestor of `pid` (itself included) that `isApp` accepts, or nil if the chain reaches launchd, loops,
    /// or runs out first.
    public static func owningApp(of pid: Int32, parent: (Int32) -> Int32?, isApp: (Int32) -> Bool) -> Int32? {
        var current = pid
        var seen = Set<Int32>()
        while current > 1, seen.insert(current).inserted, seen.count <= 32 {
            if isApp(current) { return current }
            guard let next = parent(current) else { return nil }
            current = next
        }
        return nil
    }

    /// The session a click on the orb or island means: the most pressing one we can trace to a process (needs you,
    /// then errors, then working, newest first).
    public static func target(in sessions: [Session]) -> Session? {
        SessionStore.sorted(sessions).first { $0.pid != nil }
    }

    /// When a session can't be traced to an app (Claude Code's background sessions run under its daemon, not a
    /// terminal), where to look instead: `claude` processes a person is using in a terminal, the agents view first
    /// (where background sessions are watched), then interactive sessions, newest first. Browser-extension helpers,
    /// the daemon and background hosts never count.
    public static func fallbackOrder(_ processes: [(pid: Int32, args: [String])]) -> [Int32] {
        let interactive = processes.filter { p in
            let flags = p.args.dropFirst()
            let name = p.args.first.map { ($0 as NSString).lastPathComponent } ?? ""
            guard name == "claude" else { return false }   // excludes "claude bg-spare" and the like
            return !flags.contains { ["--chrome-native-host", "--bg-pty-host", "daemon", "mcp"].contains($0) }
        }
        let agents = interactive.filter { $0.args.dropFirst().first == "agents" }
        let others = interactive.filter { $0.args.dropFirst().first != "agents" }
        return (agents + others).sorted { a, b in
            let aa = a.args.dropFirst().first == "agents", ba = b.args.dropFirst().first == "agents"
            return aa != ba ? aa : a.pid > b.pid
        }.map(\.pid)
    }
}
