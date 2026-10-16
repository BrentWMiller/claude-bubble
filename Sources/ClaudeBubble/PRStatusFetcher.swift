import ClaudeBubbleCore
import Foundation

/// Fetches each pull request's live status with the GitHub CLI (`gh`), off the main thread: about every 30s while its
/// checks are running, every 90s otherwise, and rarely once it's merged or closed. Without `gh`, it does nothing.
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

    func refresh(_ sessions: [Session]) {
        guard let gh = Self.gh else { return }
        let urls = Set(sessions.flatMap { $0.links.filter { $0.kind == .pr }.map(\.url) })
        guard !urls.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.fetching else { return }
            self.fetching = true
            defer { self.fetching = false }
            var changed = false
            let now = Date()
            for url in urls {
                let e = self.entries[url]
                let every: TimeInterval = switch e?.status {
                case nil: e == nil ? 0 : 120   // never fetched, or the last fetch failed
                case let s? where s.state == .merged || s.state == .closed: 1800
                case let s? where s.checks == .pending: 30
                default: 90
                }
                guard now.timeIntervalSince(e?.fetchedAt ?? .distantPast) >= every else { continue }
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
