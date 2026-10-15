import AppKit
import ClaudeBubbleCore
import SwiftUI

final class SettingsWindowController: NSWindowController {
    convenience init(settings: SettingsModel) {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
        window.title = "Claude Bubble Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        Form {
            Section("Colors") {
                Picker("Preset", selection: Binding(get: { settings.prefs.presetName }, set: { settings.applyPreset($0) })) {
                    ForEach(OrbPalette.presets, id: \.name) { Text($0.name).tag($0.name) }
                }
                ForEach(BubbleState.allCases, id: \.self) { state in
                    ColorPicker(state.settingsLabel, selection: color(for: state), supportsOpacity: false)
                }
                HStack {
                    Text(settings.prefs.customized ? "Customized from \(settings.prefs.presetName)" : "Matches the preset")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to preset") { settings.applyPreset(settings.prefs.presetName) }
                        .disabled(!settings.prefs.customized)
                }
            }
            Section("Orb") {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.prefs.diameter, in: OrbSize.minDiameter...OrbSize.maxDiameter, step: 1)
                        Text("\(Int(settings.prefs.diameter)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("Opacity") {
                    HStack {
                        Slider(value: $settings.prefs.opacity, in: 0.3...1)
                        Text("\(Int((settings.prefs.opacity * 100).rounded()))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
            Section("Display") {
                Toggle("Follow the pointer to other displays", isOn: $settings.prefs.followPointer)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func color(for state: BubbleState) -> Binding<Color> {
        Binding(get: { state.color(in: settings.prefs.palette) },
                set: { settings.setColor(NSColor($0), for: state) })
    }
}
