import Foundation

/// "Today" totals for the hover list, read from Claude Code's per-session job timelines.
public enum DailyActivity {
    public struct Entry: Equatable, Sendable {
        public let at: Date
        public let state: String
        public init(at: Date, state: String) {
            self.at = at
            self.state = state
        }
    }

    public struct Summary: Equatable, Sendable {
        public let working: TimeInterval
        public let sessions: Int

        public init(working: TimeInterval, sessions: Int) {
            self.working = working
            self.sessions = sessions
        }
    }

    /// Time spent in `working` within [since, now]. Each working entry lasts until the next entry of any
    /// state (or now), so repeated working entries never double count.
    public static func workingTime(_ entries: [Entry], since: Date, now: Date) -> TimeInterval {
        let sorted = entries.sorted { $0.at < $1.at }
        var total: TimeInterval = 0
        for (i, entry) in sorted.enumerated() where entry.state == "working" {
            let end = i + 1 < sorted.count ? sorted[i + 1].at : now
            let span = min(end, now).timeIntervalSince(max(entry.at, since))
            if span > 0 { total += span }
        }
        return total
    }

    /// Did anything happen since `since`: a new entry, or a working stretch carried over from before it.
    public static func wasActive(_ entries: [Entry], since: Date, now: Date = .distantFuture) -> Bool {
        entries.contains { $0.at >= since && $0.at <= now } || workingTime(entries, since: since, now: now) > 0
    }

    public static func summary(jobsDir: URL, since: Date, now: Date = Date()) -> Summary {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: jobsDir.path) else { return Summary(working: 0, sessions: 0) }
        var working: TimeInterval = 0
        var sessions = 0
        for name in names {
            let url = jobsDir.appendingPathComponent(name).appendingPathComponent("timeline.jsonl")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let entries = text.split(separator: "\n").compactMap(entry)
            let time = workingTime(entries, since: since, now: now)
            working += time
            if wasActive(entries, since: since, now: now) { sessions += 1 }
        }
        return Summary(working: working, sessions: sessions)
    }

    private struct Line: Decodable {
        let at: String
        let state: String
    }

    private static func entry(_ line: Substring) -> Entry? {
        guard let parsed = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
              let at = JobStore.parseDate(parsed.at) else { return nil }
        return Entry(at: at, state: parsed.state)
    }
}

public enum TokenFormat {
    public static func string(_ n: Int) -> String {
        switch n {
        case ..<1000: return "\(n)"
        case ..<100_000: return trimmed(Double(n) / 1000) + "k"
        case ..<1_000_000: return "\(n / 1000)k"
        default: return trimmed(Double(n) / 1_000_000) + "M"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", (value * 10).rounded(.down) / 10)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

public enum DurationFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
