import Foundation

/// Words and names dictation should listen for (no need to say what it would mishear them as): yours from Settings,
/// and your sessions' and projects' names.
public enum DictationVocabulary {
    /// What it starts with: what you'll say most when talking to Claude.
    public static let defaults = ["Claude", "Claude Bubble", "Claude Code", "repo", "worktree", "PR"]

    /// Most it hands the recogniser (it slows down, and stops helping, with too many).
    public static let limit = 100

    /// `yours` then `sessions`: trimmed, blanks dropped, each once (any case), at most `limit`. A session or project
    /// name written as a slug (claude-bubble) is also given as words (claude bubble), the way it's said.
    public static func words(yours: [String], sessions: [String]) -> [String] {
        let spoken = sessions.flatMap { name -> [String] in
            let words = name.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            return words == name ? [name] : [name, words]
        }
        var seen = Set<String>(), out: [String] = []
        for word in yours + spoken {
            let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !w.isEmpty, seen.insert(w.lowercased()).inserted else { continue }
            out.append(w)
            if out.count == limit { break }
        }
        return out
    }
}
