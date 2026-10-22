import Foundation

/// One correction to dictation: when it hears `heard` (a word or phrase, any case), it writes `meant` instead.
public struct DictationFix: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var heard: String
    public var meant: String

    public init(id: UUID = UUID(), heard: String, meant: String) {
        self.id = id
        self.heard = heard
        self.meant = meant
    }
}

/// Fixing what dictation mishears, from a list you can edit in Settings.
public enum DictationFixes {
    /// What the models reliably mishear when you talk to Claude. "Cloud" is only Claude before "bubble": on its own
    /// it's a real word.
    public static let defaults: [DictationFix] = [
        ("clawed bubble", "Claude Bubble"), ("clod bubble", "Claude Bubble"), ("cloud bubble", "Claude Bubble"),
        ("clawed", "Claude"), ("clod", "Claude"),
        ("rebo", "repo"), ("work tree", "worktree"), ("work trees", "worktrees"),
    ].map { DictationFix(heard: $0.0, meant: $0.1) }

    /// `text` with each `heard` (whole words, any case) replaced by its `meant`, longest phrases first so "clod
    /// bubble" wins over "clod". Blank entries (a row still being typed) are skipped.
    public static func apply(_ fixes: [DictationFix], to text: String) -> String {
        fixes
            .map { (heard: $0.heard.trimmingCharacters(in: .whitespaces), meant: $0.meant) }
            .filter { !$0.heard.isEmpty }
            .sorted { $0.heard.count > $1.heard.count }
            .reduce(text) { text, fix in
                // Whole words, even when the phrase starts or ends with punctuation (where \b wouldn't hold).
                let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: fix.heard) + "(?![\\p{L}\\p{N}_])"
                return text.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: fix.meant),
                                                 options: [.regularExpression, .caseInsensitive])
            }
    }
}
