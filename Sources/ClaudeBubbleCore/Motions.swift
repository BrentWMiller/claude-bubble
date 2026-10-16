import Foundation

/// What the orb's surface does while Claude is working (design: Orb States). Colour stays with the theme.
public enum Motion: String, CaseIterable, Sendable {
    case generating, read, search, edit, bash, web, mcp, compacting, waiting

    /// The design's `WORK` mode for this motion (wave, converge, radar, ripple, bash, drift, link, compact, wait).
    public var shaderMode: Float {
        switch self {
        case .generating: 0
        case .read: 17
        case .search: 12
        case .edit: 2
        case .bash: 26
        case .web: 9
        case .mcp: 23
        case .compacting: 24
        case .waiting: 25
        }
    }

    /// The motion for a tool call starting (mirrors the hook's mapping).
    public static func forTool(_ name: String) -> Motion {
        if name.hasPrefix("mcp__") { return .mcp }
        switch name {
        case "Read", "NotebookRead": return .read
        case "Grep", "Glob", "LSP", "ToolSearch": return .search
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .edit
        case "Bash", "PowerShell": return .bash
        case "WebFetch", "WebSearch": return .web
        case "Task", "Agent": return .waiting
        default: return .generating
        }
    }
}

/// Paces motion changes so rapid tool switching never strobes: a target holds for at least 0.5s, blends take
/// 1.6s, and a change that arrives mid-blend waits for the blend to finish (only the latest target is kept,
/// because the caller keeps asking for what it wants now).
public final class MotionDirector {
    public static let minHold = 0.5
    public static let blend = 1.6

    private var from: Motion = .generating
    private var to: Motion = .generating
    private var blendStart = -Double.infinity
    private var targetAt = -Double.infinity

    public init() {}

    public func update(want: Motion, now: Double) {
        guard want != to, now - targetAt >= Self.minHold, mix(now) >= 1 else { return }
        from = to
        to = want
        blendStart = now
        targetAt = now
    }

    public func frame(now: Double) -> (from: Motion, to: Motion, mix: Float) {
        (from, to, mix(now))
    }

    private func mix(_ now: Double) -> Float {
        let x = Float(min(max((now - blendStart) / Self.blend, 0), 1))
        return x * x * (3 - 2 * x)
    }
}

public struct LayerCounts: Equatable, Sendable {
    public let id: String
    public let ticks, fails, skills: Int

    public init(id: String, ticks: Int, fails: Int, skills: Int) {
        self.id = id
        self.ticks = ticks
        self.fails = fails
        self.skills = skills
    }
}

/// How many of each layer to fire since the last read.
public struct LayerEvents: Equatable, Sendable {
    public var ticks = 0, fails = 0, skills = 0

    public init(ticks: Int = 0, fails: Int = 0, skills: Int = 0) {
        self.ticks = ticks
        self.fails = fails
        self.skills = skills
    }
}

/// Turns the sessions' running counters into layer events for the focus session. Every session is baselined on
/// first sight and kept current even while unfocused, so launching or switching focus never replays old counts.
public final class LayerTracker {
    private var seen: [String: LayerCounts] = [:]

    public init() {}

    public func update(_ sessions: [LayerCounts], focus: String?) -> LayerEvents {
        var events = LayerEvents()
        var next: [String: LayerCounts] = [:]
        for c in sessions {
            next[c.id] = c
            guard c.id == focus, let old = seen[c.id] else { continue }
            // A counter going down means the session restarted: just take the new baseline.
            guard c.ticks >= old.ticks, c.fails >= old.fails, c.skills >= old.skills else { continue }
            events = LayerEvents(ticks: c.ticks - old.ticks, fails: c.fails - old.fails, skills: c.skills - old.skills)
        }
        seen = next
        return events
    }
}
