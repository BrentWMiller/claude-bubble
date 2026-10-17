import AppKit
import ClaudeBubbleCore
import Combine

/// The user's preferences, saved the moment they change.
final class SettingsModel: ObservableObject {
    @Published var prefs: BubblePreferences {
        didSet { if prefs != oldValue { prefs.save(to: .standard) } }
    }

    /// Where the orb sits on its display right now; supplied by the app.
    var currentSpot: () -> CGPoint? = { nil }

    init() {
        prefs = BubblePreferences.load(from: .standard)
    }

    func setFollowPointer(_ on: Bool) {
        prefs = prefs.withFollow(on, currentSpot: currentSpot())
    }

    func applyPreset(_ name: String) {
        guard let palette = OrbPalette.preset(named: name) else { return }
        var p = prefs
        p.palette = palette
        p.presetName = name
        p.customized = false
        prefs = p
    }

    func setColor(_ rgb: SIMD3<Float>, for color: PaletteColor) {
        var p = prefs
        p.palette[color] = rgb
        p.customized = true
        prefs = p
    }
}
