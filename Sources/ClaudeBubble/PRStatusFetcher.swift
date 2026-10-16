import ClaudeBubbleCore
import Foundation

/// Fetches each pull request's live status with the GitHub CLI (`gh`), off the main thread, on `PRPolling`'s schedule:
/// slowly in the background, fresh whenever the session list is opened. Without `gh`, it does nothing.
final class PRStatusFetcher {
    private struct Entry { let status: PRStatus?; let fetchedAt: Date }
    private let queue = DispatchQueue(label: "ClaudeBubble.pr-status", qos: .utility)
    private var entries: [URL: Entry] = [:]
    private var fetching = false
    /// Called on the main thread when a status changed.
    var onChange: (() -> Void)?

    private static let gh: String? = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    var statuses: [URL: PRStatus] {
        queue.sync { entries.compactMapValues(\.status) }
    }

    /// `looking`: the session list (or island panel) just opened.
    func refresh(_ sessions: [Session], looking: Bool = false) {
        guard let gh = Self.gh else { return }
        // Each PR, with how long its most recently active session has been quiet.
        var idle: [URL: TimeInterval] = [:]
        for s in sessions {
            let quiet = Date().timeIntervalSince(s.updatedAt)
            for l in s.links where l.kind == .pr { idle[l.url] = min(idle[l.url] ?? .infinity, quiet) }
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
                let status = Self.fetch(url, gh: gh)
                self.entries[url] = Entry(status: status ?? e?.status, fetchedAt: now)
                if status != nil, status != e?.status { changed = true }
            }
            if changed { DispatchQueue.main.async { self.onChange?() } }
        }
    }

    private static func fetch(_ url: URL, gh: String) -> PRStatus? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["pr", "view", url.absoluteString, "--json", "state,isDraft,reviewDecision,statusCheckRollup"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? PRStatus.parse(data) : nil
    }
}
