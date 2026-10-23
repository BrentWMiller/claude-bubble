import Foundation

/// One thing you said to a session, or Claude said back (its tool calls and their output left out).
public struct TranscriptTurn: Equatable, Sendable {
    public let fromUser: Bool
    public let text: String

    public init(fromUser: Bool, text: String) {
        self.fromUser = fromUser
        self.text = text
    }
}

/// What catch-up reads from a session's transcript (its JSONL file): the conversation's words, a plain line from
/// Claude's last message, and what's sent to Claude to summarise it.
public enum TranscriptText {
    /// How much of a long transcript is read at most: its latest stretch.
    static let tail: UInt64 = 2_000_000

    public static let summaryPrompt = "Below is the recent part of a Claude Code session. In one or two short sentences, at most 140 characters, say what the session got done or where it stands, and whether it needs the user. No preamble."

    /// Your words and Claude's, in order: no tool calls or results, side conversations, meta entries or command
    /// echoes (text starting with "<"); with `since`, only entries from then on (entries without a time are kept).
    public static func turns(fromJSONL data: Data, since: Date? = nil) -> [TranscriptTurn] {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainStamp = ISO8601DateFormatter()
        var turns: [TranscriptTurn] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
                  let message = entry["message"] as? [String: Any] else { continue }
            if let since, let t = entry["timestamp"] as? String, let at = stamp.date(from: t) ?? plainStamp.date(from: t), at < since {
                continue
            }
            let text: String
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { continue }
            turns.append(TranscriptTurn(fromUser: type == "user", text: trimmed))
        }
        return turns
    }

    /// Where to start reading a transcript last read up to `offset`: there, or its latest stretch when it's new to
    /// us (0) and long, or was rewritten (now shorter than `offset`).
    public static func readStart(offset: UInt64, fileSize: UInt64) -> UInt64 {
        guard offset == 0 || offset > fileSize else { return offset }
        return fileSize > tail ? fileSize - tail : 0
    }

    /// The first sentence of Claude's last message, without code blocks or markdown, at most 140 characters.
    public static func plainLine(_ turns: [TranscriptTurn]) -> String? {
        guard let last = turns.last(where: { !$0.fromUser }) else { return nil }
        var text = last.text.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*(#+|-)\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if let end = text.range(of: "(?<=[.!?])\\s", options: .regularExpression) { text = String(text[..<end.lowerBound]) }
        guard !text.isEmpty else { return nil }
        return text.count > 140 ? String(text.prefix(139)) + "…" : text
    }

    /// The prompt, then the conversation's last 14 turns (each at most 1500 characters), at most its last 12000.
    public static func summaryInput(_ turns: [TranscriptTurn]) -> String {
        let convo = turns.suffix(14).map { ($0.fromUser ? "YOU: " : "CLAUDE: ") + String($0.text.prefix(1500)) }
            .joined(separator: "\n\n")
        return summaryPrompt + "\n\n" + String(convo.suffix(12000))
    }
}
