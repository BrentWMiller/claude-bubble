public enum BubbleState: String, CaseIterable, Sendable {
    case idle, working, needs, error

    /// Higher wins when several sessions disagree.
    public var priority: Int {
        switch self {
        case .idle: 0
        case .working: 1
        case .needs: 2
        case .error: 3
        }
    }
}
