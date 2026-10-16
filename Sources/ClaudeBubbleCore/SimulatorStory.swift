/// The Multi-session Pips design's scripted story, for the Session Simulator's "Play story".
public enum SimulatorStory {
    public enum Action: Equatable, Sendable {
        case add(name: String, state: BubbleState)
        /// `index` is the session's position in order of adding.
        case set(index: Int, state: BubbleState)
    }

    public struct Step: Equatable, Sendable {
        public let at: Double
        public let action: Action
    }

    public static let namePool = [
        "Billing: CSV Import", "AI Bubble", "Docs: Getting Started", "api-server", "docs-site",
        "infra", "mobile-app", "billing", "search-index", "design-tokens"
    ]

    public static let steps: [Step] = [
        Step(at: 0.3, action: .add(name: "Billing: CSV Import", state: .working)),
        Step(at: 1.2, action: .add(name: "AI Bubble", state: .working)),
        Step(at: 2.1, action: .add(name: "Docs: Getting Started", state: .idle)),
        Step(at: 3.0, action: .set(index: 2, state: .working)),
        Step(at: 4.0, action: .set(index: 1, state: .needs)),
        Step(at: 6.0, action: .set(index: 2, state: .error)),
        Step(at: 8.0, action: .set(index: 1, state: .working)),
        Step(at: 9.0, action: .set(index: 2, state: .working)),
        Step(at: 10.4, action: .set(index: 1, state: .idle)),
        Step(at: 12.2, action: .set(index: 0, state: .idle)),
        Step(at: 14.0, action: .set(index: 2, state: .idle))
    ]

    /// Sessions (name, state) after every step up to `time`.
    public static func replay(until time: Double) -> [(name: String, state: BubbleState)] {
        var sessions: [(name: String, state: BubbleState)] = []
        for step in steps where step.at <= time {
            switch step.action {
            case let .add(name, state): sessions.append((name, state))
            case let .set(index, state) where sessions.indices.contains(index): sessions[index].state = state
            case .set: break
            }
        }
        return sessions
    }

    /// One step of the scripted session: the Orb States design's script, plus a permission wait, an error,
    /// and a usage window running down and resetting, so every look shows without touching a control.
    public struct SessionStep: Equatable, Sendable {
        public enum ToolEnd: Equatable, Sendable { case done, failed }
        public let state: BubbleState
        public let motion: Motion
        public let duration: Double
        /// A skill or plan starts with this step.
        public let skill: Bool
        public let subagents: Int
        /// How the previous step's tool call ended (nil when the previous step wasn't a tool).
        public let endsPrevious: ToolEnd?
        /// Percent of the usage window left from this step on (nil = unchanged).
        public let usageLeft: Double?
        /// The usage window resets at this step ("refreshed").
        public let resetsUsage: Bool
    }

    private struct Line {
        var state: BubbleState = .working
        let motion: Motion
        let duration: Double
        var skill = false
        var subagents = 0
        var fails = false
        var usage: Double?
        var reset = false
    }

    private static let script: [Line] = [
        Line(motion: .generating, duration: 2.2, usage: 40),
        Line(motion: .generating, duration: 1.8, skill: true),
        Line(motion: .read, duration: 0.35), Line(motion: .read, duration: 0.5), Line(motion: .read, duration: 0.4),
        Line(motion: .search, duration: 0.25), Line(motion: .search, duration: 0.3), Line(motion: .read, duration: 0.9, usage: 33),
        Line(motion: .edit, duration: 0.8),
        Line(state: .needs, motion: .bash, duration: 3),                       // approve the test run
        Line(motion: .bash, duration: 1.6, fails: true, usage: 24),            // warms; "25% left" toast
        Line(motion: .generating, duration: 1.4),
        Line(motion: .edit, duration: 0.6),
        Line(motion: .bash, duration: 5, usage: 18),
        Line(motion: .web, duration: 3),
        Line(motion: .mcp, duration: 2.5, usage: 12),
        Line(motion: .generating, duration: 1.2),
        Line(motion: .waiting, duration: 7, subagents: 3, usage: 8),           // low-usage mode; "8% left" toast
        Line(motion: .compacting, duration: 4),
        Line(state: .error, motion: .generating, duration: 3),                 // a failed turn
        Line(motion: .generating, duration: 2.5, reset: true),                 // the window resets: "refreshed"
        Line(state: .idle, motion: .generating, duration: 3)
    ]

    public static let session: [SessionStep] = script.indices.map { i in
        let line = script[i]
        var ends: SessionStep.ToolEnd?
        if i > 0, script[i - 1].state == .working, ![.generating, .compacting, .waiting].contains(script[i - 1].motion) {
            ends = script[i - 1].fails ? .failed : .done
        }
        return SessionStep(state: line.state, motion: line.motion, duration: line.duration, skill: line.skill,
                           subagents: line.subagents, endsPrevious: ends, usageLeft: line.usage, resetsUsage: line.reset)
    }

    /// The status line simulated sessions show.
    public static func detail(for state: BubbleState) -> String {
        switch state {
        case .needs: "Approve edit to auth.ts?"
        case .error: "Build failed · exit 1"
        case .working: "Running tests"
        case .idle: "Completed"
        }
    }
}
