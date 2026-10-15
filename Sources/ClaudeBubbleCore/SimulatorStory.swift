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
