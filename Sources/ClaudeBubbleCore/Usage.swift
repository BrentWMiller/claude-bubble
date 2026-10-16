import Foundation

public enum UsageFormat {
    /// Rounded up, so the number always agrees with the level: 25.4% left reads 26% (ok), 10.4% reads 11% (low).
    public static func percent(_ left: Double) -> String { "\(Int(left.rounded(.up)))%" }
}

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

    /// The wrapper saves Claude Code's status line input as is; when it was written is the file's modification time.
    public static func load(from url: URL = defaultURL) -> UsageReading? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return decode(data, capturedAt: modified)
    }

    /// Reads either the status line JSON (`rate_limits.five_hour`) or a flat `{used_percentage, resets_at, captured_at}`.
    public static func decode(_ data: Data, capturedAt: Date? = nil) -> UsageReading? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let window = ((root["rate_limits"] as? [String: Any])?["five_hour"] as? [String: Any]) ?? root
        guard let used = (window["used_percentage"] as? NSNumber)?.doubleValue,
              let resets = (window["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        let captured = capturedAt ?? (root["captured_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        return UsageReading(usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets), capturedAt: captured)
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
        guard state == .working || state == .idle else { return params }
        return blend(params, palette: palette, warm: warm, critical: critical)
    }

    /// The blend itself, whatever the state (the animator eases it in and out across state changes).
    public static func blend(_ params: OrbParams, palette: OrbPalette, warm: Float, critical: Float) -> OrbParams {
        guard warm > 0 || critical > 0 else { return params }
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
    /// A threshold toast was shown in this window (only then is its reset worth announcing).
    private var warned = false
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
            warned = false
            refreshed = now >= reading.resetsAt
            return []
        }
        var alerts: [UsageAlert] = []
        // A later reset time is a new window; a minute's drift is the same one.
        if reading.resetsAt > current.addingTimeInterval(60) {
            if !refreshed, warned { alerts.append(Self.refreshedAlert) }
            window = reading.resetsAt
            firedLow = false
            firedCritical = false
            warned = false
            refreshed = false
        } else if now >= current, !refreshed {
            // The window ran out with no newer reading.
            if warned { alerts.append(Self.refreshedAlert) }
            refreshed = true
            firedLow = false
            firedCritical = false
            warned = false
            return alerts
        }
        guard now < reading.resetsAt else { return alerts }
        let text = "\(UsageFormat.percent(left)) left · resets \(DurationFormat.string(reading.timeLeft(at: now)))"
        if left <= 10, !firedCritical {
            firedCritical = true
            firedLow = true
            warned = true
            alerts.append(UsageAlert(kind: .usageCritical, text: text))
        } else if left <= 25, !firedLow {
            firedLow = true
            warned = true
            alerts.append(UsageAlert(kind: .usageLow, text: text))
        }
        return alerts
    }

    private static let refreshedAlert = UsageAlert(kind: .usageRefreshed, text: "refreshed · 100% left")
}
