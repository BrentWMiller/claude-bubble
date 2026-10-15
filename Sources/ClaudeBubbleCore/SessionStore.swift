import Foundation

public struct Session: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    public let cwd: String
    public let updatedAt: Date

    public init(id: String, state: BubbleState, cwd: String = "", updatedAt: Date) {
        self.id = id
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
    }
}

/// Reads the per-session files written by the hook and reduces them to one state.
public enum SessionStore {
    public static let staleAfter: TimeInterval = 15 * 60
    public static let needsStaleAfter: TimeInterval = 60 * 60
    public static let deleteAfter: TimeInterval = 24 * 60 * 60

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-bubble/sessions", isDirectory: true)
    }

    private struct Record: Decodable {
        let state: String
        let cwd: String?
        let updated_at: Double
    }

    public static func load(from dir: URL, now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sessions: [Session] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let state = BubbleState(rawValue: record.state) else { continue }
            let updated = Date(timeIntervalSince1970: record.updated_at)
            if now.timeIntervalSince(updated) > deleteAfter {
                try? fm.removeItem(at: url)
                continue
            }
            sessions.append(Session(id: String(name.dropLast(5)), state: state, cwd: record.cwd ?? "", updatedAt: updated))
        }
        return sessions
    }

    public static func aggregate(_ sessions: [Session], now: Date = Date()) -> BubbleState {
        sessions
            .filter { now.timeIntervalSince($0.updatedAt) <= ($0.state == .needs ? needsStaleAfter : staleAfter) }
            .map(\.state)
            .max { $0.priority < $1.priority } ?? .idle
    }
}
