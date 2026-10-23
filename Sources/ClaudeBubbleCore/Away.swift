import Foundation

/// You left the Mac (at a time), or came back to it after leaving then.
public enum AwayEvent: Equatable, Sendable {
    case left(at: Date)
    case back(leftAt: Date)
}

/// Whether you're at the Mac: away once there's been no input for the threshold (from when the input stopped), or at
/// once when the screen locks or sleeps; back on the next input after that.
public struct AwayTracker: Sendable {
    /// When you last left (kept after you're back, for `keepsLeaveTime`).
    public private(set) var leftAt: Date?
    /// A catch-up from an earlier absence is still unseen: leaving again reports that first leave, so it adds on.
    public var keepsLeaveTime = false
    private var away = false

    public init() {}

    public mutating func update(idle: TimeInterval, threshold: TimeInterval, inactive: Bool, now: Date) -> AwayEvent? {
        if away {
            guard !inactive, idle < threshold, let leftAt else { return nil }
            away = false
            return .back(leftAt: leftAt)
        }
        guard inactive || idle >= threshold else { return nil }
        away = true
        let left = inactive ? now : now.addingTimeInterval(-idle)
        if !keepsLeaveTime || leftAt == nil { leftAt = left }
        return .left(at: leftAt!)
    }
}
