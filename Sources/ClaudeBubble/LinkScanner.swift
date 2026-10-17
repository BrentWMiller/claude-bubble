import ClaudeBubbleCore
import Foundation

/// Finds each session's GitHub issues off the main thread: the issue in its git branch name (re-read about every
/// 30s), and the issues mentioned in its conversation (its transcript, read incrementally about every 10s).
final class LinkScanner {
    private struct Repo { let branch: String?; let repo: String?; let checkedAt: Date }
    private struct Transcript { var offset: UInt64; var mentioned: [Int]; var checkedAt: Date }

    private let queue = DispatchQueue(label: "ClaudeBubble.links", qos: .utility)
    private var repos: [String: Repo] = [:]              // by cwd
    private var transcripts: [String: Transcript] = [:]  // by transcript path
    private var scanning = false
    /// What's been found, as of the last scan: the main thread reads this rather than wait for the queue (which
    /// can be busy running git and reading transcripts for every session).
    private let shownLock = NSLock()
    private var shown: (repos: [String: Repo], transcripts: [String: Transcript]) = ([:], [:])
    /// Called on the main thread when something new turned up.
    var onChange: (() -> Void)?

    /// The sessions with their issue chips added to their job links (from what's been found so far).
    func apply(to sessions: [Session]) -> [Session] {
        let (repos, transcripts) = shownLock.withLock { shown }
        return sessions.map { s in
            var s = s
            let r = repos[s.cwd]
            let mentioned = s.transcriptPath.flatMap { transcripts[$0]?.mentioned } ?? []
            s.links = SessionLinks.merge(job: s.links, branchIssue: r?.branch.flatMap(LinkFinder.issue(fromBranch:)),
                                         mentioned: mentioned, repo: r?.repo)
            return s
        }
    }

    /// Looks again where it's been a while (cheap to call often).
    func refresh(_ sessions: [Session]) {
        let targets = sessions.map { ($0.cwd, $0.transcriptPath) }
        queue.async { [weak self] in
            guard let self, !self.scanning else { return }
            self.scanning = true
            defer { self.scanning = false }
            var changed = false
            let now = Date()
            for (cwd, transcript) in targets {
                if !cwd.isEmpty, now.timeIntervalSince(self.repos[cwd]?.checkedAt ?? .distantPast) > 30 {
                    let before = self.repos[cwd]
                    let next = Repo(branch: Self.git(cwd, "rev-parse", "--abbrev-ref", "HEAD"),
                                    repo: Self.git(cwd, "config", "--get", "remote.origin.url").flatMap(LinkFinder.repo(fromRemote:)),
                                    checkedAt: now)
                    self.repos[cwd] = next
                    if before?.branch != next.branch || before?.repo != next.repo { changed = true }
                }
                if let path = transcript, now.timeIntervalSince(self.transcripts[path]?.checkedAt ?? .distantPast) > 10 {
                    if self.scan(path, repo: self.repos[cwd]?.repo, now: now) { changed = true }
                }
            }
            if changed {
                self.shownLock.withLock { self.shown = (self.repos, self.transcripts) }
                DispatchQueue.main.async { self.onChange?() }
            }
        }
    }

    /// Reads what's been added to a transcript since last time; returns whether new issues turned up.
    private func scan(_ path: String, repo: String?, now: Date) -> Bool {
        var t = transcripts[path] ?? Transcript(offset: 0, mentioned: [], checkedAt: now)
        t.checkedAt = now
        defer { transcripts[path] = t }
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end < t.offset { t = Transcript(offset: 0, mentioned: [], checkedAt: now) }   // rewritten
        // A long conversation's first look: just its latest stretch.
        let start = t.offset == 0 && end > 2_000_000 ? end - 2_000_000 : t.offset
        guard end > start else { return false }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(end - start)), let text = String(data: data, encoding: .utf8) else {
            t.offset = end
            return false
        }
        t.offset = end
        let found = LinkFinder.issues(inText: text, repo: repo).filter { repo == nil || $0.repo == repo }.map(\.number)
        let before = t.mentioned
        // Keep the order they were last mentioned in (the latest matters most).
        t.mentioned = t.mentioned.filter { !found.contains($0) } + found
        if t.mentioned.count > 20 { t.mentioned.removeFirst(t.mentioned.count - 20) }
        return t.mentioned != before
    }

    private static func git(_ cwd: String, _ args: String...) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
