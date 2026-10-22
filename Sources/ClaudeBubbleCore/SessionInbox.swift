import Foundation

/// Where a running Claude Code session takes messages: the Unix socket it listens on for other sessions (its
/// "inbox"), and the token a sender authenticates with. Claude Code publishes both in its session registry.
public struct InboxPeer: Equatable, Sendable {
    public let socketPath: String
    /// The `peerToken` from the session's key file; nil when it has none (auth is optional on macOS).
    public let token: String?
}

/// Sending the user's words and drops to a session through its inbox, so they reach Claude without the terminal.
/// The registry (`~/.claude/sessions/<pid>.json` and `<pid>.<hash>.key`) and the wire format are Claude Code
/// internals, so every field is optional and anything unexpected means "can't send", never a crash.
public enum SessionInbox {
    public static var registryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// Where drops that aren't files yet (images, long text) are written, so the message can name a path.
    public static var dropsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-bubble/drops", isDirectory: true)
    }

    /// The inbox protocol this speaks; a session announcing another one isn't sent to.
    public static let peerProtocol = 1

    /// Text longer than this is dropped as a file and sent as its path.
    public static let inlineTextLimit = 2000

    private struct Registration: Decodable {
        let pid: Int32?
        let sessionId: String?
        let messagingSocketPath: String?
        let peerProtocol: Int?
    }

    private struct Key: Decodable {
        let peerToken: String?
    }

    /// The inbox of session `sessionId`: its own registration (`<pid>.json`) when `pid` is known, else whichever
    /// registration names it (background sessions are registered under another process).
    public static func peer(sessionId: String, pid: Int32?, in dir: URL = registryDirectory) -> InboxPeer? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let pid { candidates.append(dir.appendingPathComponent("\(pid).json")) }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        candidates += names.filter { $0.hasSuffix(".json") }.sorted().map { dir.appendingPathComponent($0) }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let reg = try? JSONDecoder().decode(Registration.self, from: data),
                  reg.sessionId == sessionId, let socket = reg.messagingSocketPath, !socket.isEmpty,
                  (reg.peerProtocol ?? peerProtocol) == peerProtocol else { continue }
            let pidName = reg.pid.map(String.init) ?? url.deletingPathExtension().lastPathComponent
            return InboxPeer(socketPath: socket, token: token(pid: pidName, names: names, in: dir))
        }
        return nil
    }

    private static func token(pid: String, names: [String], in dir: URL) -> String? {
        guard let name = names.first(where: { $0.hasPrefix(pid + ".") && $0.hasSuffix(".key") }),
              let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return (try? JSONDecoder().decode(Key.self, from: data))?.peerToken
    }

    /// What goes down the socket: an auth line when there's a token, then the message, one JSON object per line.
    /// Only a plain-string `content` is delivered (content blocks, images included, are dropped).
    public static func payload(_ text: String, token: String?) -> Data {
        var lines: [[String: Any]] = []
        if let token { lines.append(["type": "auth", "token": token]) }
        lines.append(["type": "user", "message": ["role": "user", "content": text]])
        return lines.reduce(into: Data()) { data, line in
            data += (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
            data += Data("\n".utf8)
        }
    }

    /// The message for words said to the bubble. It arrives as another session's message, so it says who it's from.
    public static func spoken(_ transcript: String) -> String? {
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : "Voice message from the user, sent from Claude Bubble:\n\n" + words
    }

    /// The message for things dropped on a session: files by path (Claude reads them itself), short text inline.
    public static func dropped(files: [URL], texts: [String]) -> String? {
        let texts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !files.isEmpty || !texts.isEmpty else { return nil }
        var parts = ["The user dropped this on the session in Claude Bubble:"]
        if !files.isEmpty {
            parts.append(files.map { "- " + $0.path }.joined(separator: "\n"))
        }
        parts += texts
        return parts.joined(separator: "\n\n")
    }

    /// Writes a drop with no file behind it (a pasted image, a long snippet) to `dir`, named by `date`, and returns
    /// where. Nil when it can't be written.
    public static func stage(_ data: Data, ext: String, at date: Date = Date(), in dir: URL = dropsDirectory) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("drop-\(f.string(from: date)).\(ext)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Drops older than this are cleared out (they only need to last until Claude reads them).
    public static let keepDropsFor: TimeInterval = 7 * 24 * 60 * 60

    public static func pruneDrops(now: Date = Date(), in dir: URL = dropsDirectory) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in urls where url.lastPathComponent.hasPrefix("drop-") {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > keepDropsFor { try? fm.removeItem(at: url) }
        }
    }
}
