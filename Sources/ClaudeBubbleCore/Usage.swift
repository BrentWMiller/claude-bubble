import Foundation

public enum UsageLevel: Equatable, Sendable {
    /// More than 25% left.
    case ok
    /// 10–25% left.
    case low
    /// 10% or less left.
    case critical
}

/// The 5-hour usage window, as the status line wrapper last saw it (`~/.claude-bubble/usage.json`).
public struct UsageReading: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date
    public let capturedAt: Date

    public init(usedPercent: Double, resetsAt: Date, capturedAt: Date) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.capturedAt = capturedAt
    }

    public static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_BUBBLE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-bubble")
        return base.appendingPathComponent("usage.json")
    }

    public static func load(from url: URL = defaultURL) -> UsageReading? {
        (try? Data(contentsOf: url)).flatMap(decode)
    }

    public static func decode(_ data: Data) -> UsageReading? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let used = (object["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (object["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        let captured = (object["captured_at"] as? NSNumber)?.doubleValue ?? resets
        return UsageReading(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets),
                            capturedAt: Date(timeIntervalSince1970: captured))
    }

    /// Percent of the window left; a window whose reset time has passed is full again.
    public func left(at now: Date) -> Double {
        now >= resetsAt ? 100 : min(max(100 - usedPercent, 0), 100)
    }

    public func level(at now: Date) -> UsageLevel {
        let left = left(at: now)
        return left <= 10 ? .critical : left <= 25 ? .low : .ok
    }

    public func timeLeft(at now: Date) -> TimeInterval {
        max(0, resetsAt.timeIntervalSince(now))
    }
}

/// The orb's colour temperature: its rim and glow warm toward the palette's needs colours from 50% to 25% left,
/// then toward its error colours down to 0. The body colour (c2) is left alone.
public enum UsageTint {
    public static func amounts(left: Double) -> (warm: Float, critical: Float) {
        (Float(min(max((50 - left) / 25, 0), 1)), Float(min(max((25 - left) / 25, 0), 1)))
    }

    public static func apply(_ params: OrbParams, state: BubbleState, palette: OrbPalette,
                             warm: Float, critical: Float) -> OrbParams {
        // Needs and error already wear these colours.
        guard state == .working || state == .idle, warm > 0 || critical > 0 else { return params }
        var p = params
        for (target, amount) in [(palette.needs, warm), (palette.error, critical)] where amount > 0 {
            p.c1 += (target.c1 - p.c1) * amount
            p.c3 += (target.c3 - p.c3) * amount
            p.halo += (target.halo - p.halo) * amount
        }
        return p
    }
}

public struct UsageAlert: Equatable, Sendable {
    public let kind: ToastKind
    public let text: String

    public init(kind: ToastKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Decides the threshold toasts: once per window at 25% and 10% left, and "refreshed" when a window that
/// warned resets. The first reading (at launch, or after `reset`) only sets the baseline.
public final class UsageAlerts {
    private var window: Date?
    private var firedLow = false
    private var firedCritical = false
    /// This window's reset has already been announced (or wasn't worth announcing).
    private var refreshed = false

    public init() {}

    public func reset() {
        window = nil
    }

    public func update(_ reading: UsageReading?, now: Date) -> [UsageAlert] {
        guard let reading else { return [] }
        let left = reading.left(at: now)
        guard let current = window else {
            window = reading.resetsAt
            firedCritical = left <= 10
            firedLow = left <= 25
            refreshed = now >= reading.resetsAt
            return []
        }
        var alerts: [UsageAlert] = []
        if reading.resetsAt > current {
            // A new window.
            if !refreshed, firedLow || firedCritical { alerts.append(Self.refreshedAlert) }
            window = reading.resetsAt
            firedLow = false
            firedCritical = false
            refreshed = false
        } else if now >= current, !refreshed {
            // The window ran out with no newer reading.
            if firedLow || firedCritical { alerts.append(Self.refreshedAlert) }
            refreshed = true
            firedLow = false
            firedCritical = false
            return alerts
        }
        guard now < reading.resetsAt else { return alerts }
        let text = "\(Int(left.rounded()))% left · resets \(DurationFormat.string(reading.timeLeft(at: now)))"
        if left <= 10, !firedCritical {
            firedCritical = true
            firedLow = true
            alerts.append(UsageAlert(kind: .usageCritical, text: text))
        } else if left <= 25, !firedLow {
            firedLow = true
            alerts.append(UsageAlert(kind: .usageLow, text: text))
        }
        return alerts
    }

    private static let refreshedAlert = UsageAlert(kind: .usageRefreshed, text: "refreshed · 100% left")
}
