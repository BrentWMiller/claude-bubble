import CoreGraphics
import Foundation

public enum OrbSize {
    public static let minDiameter: Double = 40
    public static let maxDiameter: Double = 800
    public static let defaultDiameter: Double = 72

    /// How far quiet shrinks an orb of `diameter`: to the island's orb, the same small dot whatever the orb's size.
    public static func quietScale(forDiameter diameter: Double) -> Double {
        min(1, Double(IslandLayout.orbSize) * 0.6 / min(max(diameter, minDiameter), maxDiameter))
    }

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
    public var interaction: PointerInteraction
    /// Pip sounds on or off.
    public var sounds: Bool
    /// How loud pip sounds play (0…1).
    public var soundVolume: Double
    /// What plays when every session finishes.
    public var completionSound: CompletionSound
    /// Toasts under the orb on or off.
    public var toasts: Bool
    /// Usage (5-hour window) on the orb, the hover card, and as toasts.
    public var usage: Bool
    /// A light along the screen edge when the orb is near it.
    public var edgeLight: Bool
    /// The floating orb, or a pill docked to a screen edge.
    public var style: BubbleStyle
    public var islandDock: IslandDock
    public var islandRest: IslandRest
    public var islandGlow: IslandGlow
    /// Where along its edge the island sits (0…1; dragging sets it).
    public var islandAlong: Double
    /// How wide the island is, as a multiple of the design's widths (IslandLayout.minWidth…maxWidth).
    public var islandWidth: Double
    /// Quiet mode: the bubble shrinks to a dot, toasts wait for a catch-up and sounds are muted.
    public var quiet: Bool
    /// Permission prompts can be approved or denied from the bubble (the terminal's prompt shows too).
    public var approvals: Bool

    public static let defaults = BubblePreferences(
        palette: .agentsView, presetName: "Agents view", customized: false,
        diameter: OrbSize.defaultDiameter, opacity: 1, followPointer: false, relativeSpot: nil,
        interaction: .attention, sounds: true, completionSound: .bloom, toasts: true, usage: true, edgeLight: true)
        .with(style: .orb, dock: .top, rest: .live, glow: .waves)

    public init(palette: OrbPalette, presetName: String, customized: Bool, diameter: Double, opacity: Double,
                followPointer: Bool, relativeSpot: [Double]?, interaction: PointerInteraction, sounds: Bool,
                completionSound: CompletionSound, toasts: Bool, usage: Bool = true, edgeLight: Bool = true) {
        self.palette = palette
        self.presetName = presetName
        self.customized = customized
        self.diameter = diameter
        self.opacity = opacity
        self.followPointer = followPointer
        self.relativeSpot = relativeSpot
        self.interaction = interaction
        self.sounds = sounds
        soundVolume = 1
        self.completionSound = completionSound
        self.toasts = toasts
        self.usage = usage
        self.edgeLight = edgeLight
        style = .orb
        islandDock = .top
        islandRest = .live
        islandGlow = .waves
        islandAlong = 0.5
        islandWidth = 1
        quiet = false
        approvals = true
    }

    func with(style: BubbleStyle, dock: IslandDock, rest: IslandRest, glow: IslandGlow) -> BubblePreferences {
        var p = self
        p.style = style
        p.islandDock = dock
        p.islandRest = rest
        p.islandGlow = glow
        return p
    }

    /// Missing keys (settings saved by an older version) take their defaults instead of resetting everything.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BubblePreferences.defaults
        palette = try c.decodeIfPresent(OrbPalette.self, forKey: .palette) ?? d.palette
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName) ?? d.presetName
        customized = try c.decodeIfPresent(Bool.self, forKey: .customized) ?? d.customized
        diameter = try c.decodeIfPresent(Double.self, forKey: .diameter) ?? d.diameter
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? d.opacity
        followPointer = try c.decodeIfPresent(Bool.self, forKey: .followPointer) ?? d.followPointer
        relativeSpot = try c.decodeIfPresent([Double].self, forKey: .relativeSpot)
        interaction = (try? c.decodeIfPresent(PointerInteraction.self, forKey: .interaction)) ?? d.interaction
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        soundVolume = (try? c.decodeIfPresent(Double.self, forKey: .soundVolume)) ?? d.soundVolume
        completionSound = (try? c.decodeIfPresent(CompletionSound.self, forKey: .completionSound)) ?? d.completionSound
        toasts = try c.decodeIfPresent(Bool.self, forKey: .toasts) ?? d.toasts
        usage = try c.decodeIfPresent(Bool.self, forKey: .usage) ?? d.usage
        edgeLight = try c.decodeIfPresent(Bool.self, forKey: .edgeLight) ?? d.edgeLight
        style = (try? c.decodeIfPresent(BubbleStyle.self, forKey: .style)) ?? d.style
        islandDock = (try? c.decodeIfPresent(IslandDock.self, forKey: .islandDock)) ?? d.islandDock
        islandRest = (try? c.decodeIfPresent(IslandRest.self, forKey: .islandRest)) ?? d.islandRest
        islandGlow = (try? c.decodeIfPresent(IslandGlow.self, forKey: .islandGlow)) ?? d.islandGlow
        islandAlong = (try? c.decodeIfPresent(Double.self, forKey: .islandAlong)) ?? d.islandAlong
        islandWidth = (try? c.decodeIfPresent(Double.self, forKey: .islandWidth)) ?? d.islandWidth
        quiet = (try? c.decodeIfPresent(Bool.self, forKey: .quiet)) ?? d.quiet
        approvals = (try? c.decodeIfPresent(Bool.self, forKey: .approvals)) ?? d.approvals
    }

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
        p.soundVolume = min(max(soundVolume, 0), 1)
        p.islandAlong = min(max(islandAlong, 0), 1)
        p.islandWidth = min(max(islandWidth, Double(IslandLayout.minWidth)), Double(IslandLayout.maxWidth))
        if OrbPalette.preset(named: presetName) == nil { p.presetName = "Agents view" }
        if let spot = relativeSpot, spot.count != 2 { p.relativeSpot = nil }
        return p
    }
}
