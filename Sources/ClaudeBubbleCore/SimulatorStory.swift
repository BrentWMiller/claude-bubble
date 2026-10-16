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

    /// One step of the Orb States design's scripted session.
    public struct SessionStep: Equatable, Sendable {
        public enum ToolEnd: Equatable, Sendable { case done, failed }
        /// nil = the session finished (idle).
        public let motion: Motion?
        public let duration: Double
        /// A skill or plan starts with this step.
        public let skill: Bool
        public let subagents: Int
        /// How the previous step's tool call ended (nil when the previous step wasn't a tool).
        public let endsPrevious: ToolEnd?
    }

    /// The Orb States design's script (motion, seconds, skill, subagents, whether that step's tool fails).
    private static let script: [(Motion?, Double, Bool, Int, Bool)] = [
        (.generating, 2.2, false, 0, false), (.generating, 1.8, true, 0, false),
        (.read, 0.35, false, 0, false), (.read, 0.5, false, 0, false), (.read, 0.4, false, 0, false),
        (.search, 0.25, false, 0, false), (.search, 0.3, false, 0, false), (.read, 0.9, false, 0, false),
        (.edit, 0.8, false, 0, false), (.bash, 1.6, false, 0, true), (.generating, 1.4, false, 0, false),
        (.edit, 0.6, false, 0, false), (.bash, 5, false, 0, false), (.web, 3, false, 0, false),
        (.mcp, 2.5, false, 0, false), (.generating, 1.2, false, 0, false), (.waiting, 7, false, 3, false),
        (.compacting, 4, false, 0, false), (.generating, 2.5, false, 0, false), (nil, 3, false, 0, false)
    ]

    public static let session: [SessionStep] = script.indices.map { i in
        let (motion, duration, skill, subagents, _) = script[i]
        var ends: SessionStep.ToolEnd?
        if i > 0, let prior = script[i - 1].0, ![.generating, .compacting, .waiting].contains(prior) {
            ends = script[i - 1].4 ? .failed : .done
        }
        return SessionStep(motion: motion, duration: duration, skill: skill, subagents: subagents, endsPrevious: ends)
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
