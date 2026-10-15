import AppKit
import ClaudeBubbleCore
import Combine

/// The user's preferences, saved the moment they change.
final class SettingsModel: ObservableObject {
    @Published var prefs: BubblePreferences {
        didSet { if prefs != oldValue { prefs.save(to: .standard) } }
    }

    init() {
        prefs = BubblePreferences.load(from: .standard)
    }

    func applyPreset(_ name: String) {
        guard let palette = OrbPalette.preset(named: name) else { return }
        var p = prefs
        p.palette = palette
        p.presetName = name
        p.customized = false
        prefs = p
    }

    func setColor(_ color: NSColor, for state: BubbleState) {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        var p = prefs
        p.palette[state] = PaletteDerivation.colors(from: [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)])
        p.customized = true
        prefs = p
    }
}
