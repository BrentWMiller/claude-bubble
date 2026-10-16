import Foundation

/// A toast held back during quiet mode, to play in the catch-up.
public struct HeldToast: Equatable, Sendable {
    public let kind: ToastKind
    public let name: String
    /// Its own text (usage toasts), or nil for the kind's.
    public let text: String?

    public init(kind: ToastKind, name: String, text: String?) {
        self.kind = kind
        self.name = name
        self.text = text
    }
}

public struct CatchUpItem: Equatable, Sendable {
    /// Seconds after quiet mode ends.
    public let delay: Double
    public let kind: ToastKind
    public let name: String
    public let text: String?
}

/// When quiet mode ends, the held toasts play back quickly: all of them if there are up to five, otherwise a
/// "While you were away" summary and then the five most recent.
public enum CatchUp {
    public static let spacing = 0.35
    public static let shown = 5

    public static func plan(_ held: [HeldToast]) -> [CatchUpItem] {
        guard !held.isEmpty else { return [] }
        var items: [(ToastKind, String, String?)] = []
        if held.count > shown { items.append((.catchUp, "While you were away", summary(held))) }
        items += held.suffix(shown).map { ($0.kind, $0.name, $0.text) }
        return items.enumerated().map { i, item in
            CatchUpItem(delay: Double(i) * spacing, kind: item.0, name: item.1, text: item.2)
        }
    }

    /// "3 finished · 1 needs you · 1 error", or "6 updates" when nothing finished, needs you or failed.
    public static func summary(_ held: [HeldToast]) -> String {
        let finished = held.filter { [.finished, .review, .allDone].contains($0.kind) }.count
        let needs = held.filter { $0.kind == .needs }.count
        let errors = held.filter { $0.kind == .error }.count
        var parts: [String] = []
        if finished > 0 { parts.append("\(finished) finished") }
        if needs > 0 { parts.append("\(needs) \(needs == 1 ? "needs" : "need") you") }
        if errors > 0 { parts.append("\(errors) \(errors == 1 ? "error" : "errors")") }
        return parts.isEmpty ? "\(held.count) \(held.count == 1 ? "update" : "updates")" : parts.joined(separator: " · ")
    }
}
