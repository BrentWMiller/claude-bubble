import CoreGraphics
import Foundation

public enum OrbSize {
    public static let minDiameter: Double = 40
    public static let maxDiameter: Double = 160
    public static let defaultDiameter: Double = 72

    /// The orb fills 60% of its panel; the rest is room for the halo and pips.
    public static func panelSide(forDiameter diameter: Double) -> CGFloat {
        CGFloat(min(max(diameter, minDiameter), maxDiameter) / 0.6)
    }
}

/// Everything the Settings window controls, saved as one JSON blob.
public struct BubblePreferences: Codable, Equatable, Sendable {
    public static let key = "preferences"

    public var palette: OrbPalette
    public var presetName: String
    /// True once a color well has changed the preset.
    public var customized: Bool
    public var diameter: Double
    public var opacity: Double
    public var followPointer: Bool
    /// The orb centre as [fraction across, fraction up] a display's visible area; shared by all displays.
    public var relativeSpot: [Double]?

    public static let defaults = BubblePreferences(
        palette: .agentsView, presetName: "Agents view", customized: false,
        diameter: OrbSize.defaultDiameter, opacity: 1, followPointer: false, relativeSpot: nil)

    public static func load(from store: UserDefaults) -> BubblePreferences {
        guard let data = store.data(forKey: key),
              let prefs = try? JSONDecoder().decode(BubblePreferences.self, from: data) else { return .defaults }
        return prefs.clamped()
    }

    public func save(to store: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { store.set(data, forKey: Self.key) }
    }

    /// Turning follow on remembers where the orb sits now, so it reappears there on other displays.
    public func withFollow(_ on: Bool, currentSpot: CGPoint?) -> BubblePreferences {
        var p = self
        p.followPointer = on
        if on, let spot = currentSpot { p.relativeSpot = [Double(spot.x), Double(spot.y)] }
        return p
    }

    public func clamped() -> BubblePreferences {
        var p = self
        p.diameter = min(max(diameter, OrbSize.minDiameter), OrbSize.maxDiameter)
        p.opacity = min(max(opacity, 0.3), 1)
        if OrbPalette.preset(named: presetName) == nil { p.presetName = "Agents view" }
        if let spot = relativeSpot, spot.count != 2 { p.relativeSpot = nil }
        return p
    }
}
