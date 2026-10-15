/// One-click choices for the orb's context menu and the menu-bar menu.
public enum QuickPicks {
    public struct Size: Equatable, Sendable {
        public let label: String
        public let diameter: Double
    }

    public static let sizes = [
        Size(label: "Small", diameter: 48), Size(label: "Medium", diameter: 72),
        Size(label: "Large", diameter: 104), Size(label: "Extra large", diameter: 144)
    ]
    public static let opacities: [Double] = [1, 0.8, 0.6, 0.4]

    /// The quick size to tick, if the current diameter is one of them (a slider value in between ticks none).
    public static func checkedSize(_ diameter: Double) -> Double? {
        sizes.map(\.diameter).first { abs($0 - diameter) < 0.5 }
    }

    public static func checkedOpacity(_ opacity: Double) -> Double? {
        opacities.first { abs($0 - opacity) < 0.005 }
    }

    public static func isChecked(preset name: String, in prefs: BubblePreferences) -> Bool {
        name == prefs.presetName && !prefs.customized
    }

    public static func title(forPreset name: String, in prefs: BubblePreferences) -> String {
        name == prefs.presetName && prefs.customized ? "\(name) (customized)" : name
    }
}
