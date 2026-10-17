import ClaudeBubbleCore
import Foundation

/// Fetches each pull request's (and issue's) live status with the GitHub CLI (`gh`), off the main thread, on `PRPolling`'s schedule:
/// slowly in the background, fresh whenever the session list is opened. Without `gh`, it does nothing.
final class PRStatusFetcher {
    private struct Entry { let status: PRStatus?; let fetchedAt: Date }
    private let queue = DispatchQueue(label: "ClaudeBubble.pr-status", qos: .utility)
    private var entries: [URL: Entry] = [:]
    private var fetching = false
    /// Called on the main thread when a status changed.
    var onChange: (() -> Void)?

    private static let ghLock = NSLock()
    private static var ghLooked = false
    private static var ghPath: String?

    /// The GitHub CLI, once `resolveGH()` has found it. Never blocks, so it's safe on the main thread.
    static var gh: String? {
        ghLock.lock(); defer { ghLock.unlock() }
        return ghPath
    }

    /// Finds the GitHub CLI: the usual install places, else wherever the user's shell finds it (MacPorts, Nix,
    /// ~/bin…), giving up after 3 seconds. Looks once; call it off the main thread.
    @discardableResult
    static func resolveGH() -> String? {
        ghLock.lock()
        if ghLooked { defer { ghLock.unlock() }; return ghPath }
        ghLock.unlock()
        let found = findGH()
        ghLock.lock(); defer { ghLock.unlock() }
        ghLooked = true
        ghPath = found
        return found
    }

    private static func findGH() -> String? {
        let usual = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let found = usual.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return found }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-ilc", "command -v gh"]   // interactive too, for a PATH set only in .zshrc
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + 3) == .timedOut {
            p.terminate()
            return nil
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // Shell start-up files can print things too: the answer is the last line that's a path.
        let path = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
        return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    var statuses: [URL: PRStatus] {
        queue.sync { entries.compactMapValues(\.status) }
    }

    /// `looking`: the session list (or island panel) just opened.
    func refresh(_ sessions: [Session], looking: Bool = false) {
        guard let gh = Self.gh else { return }
        // Each PR, with how long its most recently active session has been quiet.
        var idle: [URL: TimeInterval] = [:]
        var issues = Set<URL>()
        for s in sessions {
            let quiet = Date().timeIntervalSince(s.updatedAt)
            for l in s.links where l.kind != .artifact {
                idle[l.url] = min(idle[l.url] ?? .infinity, quiet)
                if l.kind == .issue { issues.insert(l.url) }
            }
        }
        guard !idle.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.fetching else { return }
            self.fetching = true
            defer { self.fetching = false }
            var changed = false
            let now = Date()
            for (url, quiet) in idle {
                let e = self.entries[url]
                guard let every = PRPolling.interval(status: e?.status, fetched: e != nil, looking: looking, sessionIdle: quiet),
                      now.timeIntervalSince(e?.fetchedAt ?? .distantPast) >= every else { continue }
                let status = Self.fetch(url, issue: issues.contains(url), gh: gh)
                self.entries[url] = Entry(status: status ?? e?.status, fetchedAt: now)
                if status != nil, status != e?.status { changed = true }
            }
            if changed { DispatchQueue.main.async { self.onChange?() } }
        }
    }

    private static func fetch(_ url: URL, issue: Bool, gh: String) -> PRStatus? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = issue ? ["issue", "view", url.absoluteString, "--json", "state"]
                            : ["pr", "view", url.absoluteString, "--json", "state,isDraft,reviewDecision,statusCheckRollup"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? PRStatus.parse(data) : nil
    }
}
