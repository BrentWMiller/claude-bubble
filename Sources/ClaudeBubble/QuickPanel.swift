import AppKit
import ClaudeBubbleCore
import SwiftUI

/// What the quick panel's buttons do (supplied by the app).
struct QuickPanelActions {
    var openSettings: () -> Void
    var toggleHidden: () -> Void
    var resetPosition: () -> Void
    var restart: () -> Void
    var quit: () -> Void
    /// Pops the Debug menu at the given screen point.
    var debugMenu: (CGPoint) -> Void
    var previewSound: (CompletionSound) -> Void
}

/// The right-click panel: the bubble's own dark card with one-click controls, instead of a system menu.
final class QuickPanel: NSPanel {
    static let width: CGFloat = 316
    private var monitors: [Any] = []
    private let host: NSHostingView<QuickPanelView>

    init(settings: SettingsModel, actions: QuickPanelActions) {
        let view = QuickPanelView(settings: settings, actions: actions, close: {})
        host = NSHostingView(rootView: view)
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        host.rootView = QuickPanelView(settings: settings, actions: actions, close: { [weak self] in self?.dismiss() })
        contentView = host
    }

    // Key, so Esc closes it and the controls take the keyboard; never main.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Opens with its top-left at `point` (screen space), kept on that screen.
    func show(at point: CGPoint) {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: point.x + 4, y: point.y - size.height - 4)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        host.rootView.appeared.reset()
        makeKeyAndOrderFront(nil)
        // A click anywhere else closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(m)
        }
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard isVisible else { return }
        orderOut(nil)
    }
}

/// Drives the panel's pop-in each time it opens.
final class Appeared: ObservableObject {
    @Published var shown = false
    func reset() {
        shown = false
        DispatchQueue.main.async { withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { self.shown = true } }
    }
}

struct QuickPanelView: View {
    @ObservedObject var settings: SettingsModel
    let actions: QuickPanelActions
    let close: () -> Void
    @ObservedObject var appeared = Appeared()
    @State private var hoveredTheme: String?

    private var prefs: BubblePreferences { settings.prefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            styleSection
            divider
            themeSection
            divider
            sliders
            divider
            switches
            divider
            footer
        }
        .padding(.vertical, 6)
        .frame(width: QuickPanel.width)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .padding(1)
        .scaleEffect(appeared.shown ? 1 : 0.94, anchor: .topLeading)
        .opacity(appeared.shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 4)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.4))
    }

    // MARK: Style

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Segmented(options: [(BubbleStyle.orb, "circle.circle", "Orb"), (.island, "capsule", "Island")],
                          selection: Binding(get: { prefs.style }, set: { settings.prefs.style = $0 }))
                Spacer(minLength: 4)
                Pill(icon: prefs.quiet ? "moon.fill" : "moon", text: "Quiet", on: prefs.quiet) { settings.prefs.quiet.toggle() }
            }
            if prefs.style == .island {
                HStack(spacing: 8) {
                    Text("Dock").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                    Segmented(options: IslandDock.allCases.map { ($0, icon(for: $0), $0.rawValue.capitalized) },
                              selection: Binding(get: { prefs.islandDock }, set: { settings.prefs.islandDock = $0 }),
                              compact: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func icon(for dock: IslandDock) -> String {
        switch dock {
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        case .left: "arrow.left.to.line"
        case .right: "arrow.right.to.line"
        }
    }

    // MARK: Themes

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                label("Theme")
                Spacer()
                Text(hoveredTheme ?? (prefs.customized ? "Custom" : prefs.presetName))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 8), alignment: .leading, spacing: 8) {
                ForEach(OrbPalette.presets, id: \.name) { preset in
                    ThemeSwatch(palette: preset.palette, selected: !prefs.customized && prefs.presetName == preset.name)
                        .onHover { hoveredTheme = $0 ? preset.name : (hoveredTheme == preset.name ? nil : hoveredTheme) }
                        .onTapGesture { settings.applyPreset(preset.name) }
                        .help(preset.name)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(spacing: 8) {
            sliderRow("Size", value: Binding(get: { prefs.diameter }, set: { settings.prefs.diameter = $0.rounded() }),
                      range: OrbSize.minDiameter...OrbSize.maxDiameter, text: "\(Int(prefs.diameter))pt")
            sliderRow("Opacity", value: Binding(get: { prefs.opacity }, set: { settings.prefs.opacity = $0 }),
                      range: 0.3...1, text: "\(Int((prefs.opacity * 100).rounded()))%")
            HStack(spacing: 8) {
                Text("Pointer").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55)).frame(width: 58, alignment: .leading)
                Segmented(options: PointerInteraction.allCases.map { ($0, $0 == .off ? "hand.raised.slash" : "sparkles", $0.label) },
                          selection: Binding(get: { prefs.interaction }, set: { settings.prefs.interaction = $0 }), compact: false)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55)).frame(width: 58, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small).tint(Color.white.opacity(0.8))
            Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Switches

    private var switches: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                Pill(icon: "text.bubble", text: "Toasts", on: prefs.toasts) { settings.prefs.toasts.toggle() }
                Pill(icon: "gauge.with.dots.needle.33percent", text: "Usage", on: prefs.usage) { settings.prefs.usage.toggle() }
                Pill(icon: "rectangle.dashed", text: "Edge light", on: prefs.edgeLight) { settings.prefs.edgeLight.toggle() }
                Pill(icon: prefs.sounds ? "speaker.wave.2" : "speaker.slash", text: "Sounds", on: prefs.sounds) { settings.prefs.sounds.toggle() }
                Pill(icon: "cursorarrow.motionlines", text: "Follow pointer", on: prefs.followPointer) {
                    settings.setFollowPointer(!prefs.followPointer)
                }
            }
            HStack(spacing: 8) {
                Text("Finish sound").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Menu {
                    ForEach(CompletionSound.allCases, id: \.self) { option in
                        Button(option.label) {
                            settings.prefs.completionSound = option
                            actions.previewSound(option)
                        }
                    }
                } label: {
                    Text(prefs.completionSound.label).font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { actions.previewSound(prefs.completionSound) } label: { Image(systemName: "play.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.7))
                    .help("Preview")
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                FooterButton(icon: "gearshape", text: "Settings") { close(); actions.openSettings() }
                FooterButton(icon: "arrow.counterclockwise", text: "Reset") { close(); actions.resetPosition() }
                FooterButton(icon: "ladybug", text: "Debug") { actions.debugMenu(NSEvent.mouseLocation) }
            }
            HStack(spacing: 2) {
                FooterButton(icon: "eye.slash", text: "Hide") { close(); actions.toggleHidden() }
                FooterButton(icon: "arrow.clockwise.circle", text: "Restart") { actions.restart() }
                FooterButton(icon: "power", text: "Quit", danger: true) { actions.quit() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// A theme's swatch: its working colours swirled together, ringed when it's the current theme.
private struct ThemeSwatch: View {
    let palette: OrbPalette
    let selected: Bool
    @State private var hover = false

    private func color(_ c: SIMD3<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    var body: some View {
        let w = palette.working
        Circle()
            .fill(AngularGradient(colors: [color(w.c1), color(w.c2), color(w.c3), color(w.c1)], center: .center))
            .overlay(Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 2, endRadius: 13)))
            .overlay(Circle().stroke(Color.white.opacity(selected ? 0.95 : hover ? 0.5 : 0.12), lineWidth: selected ? 2 : 1).padding(-2.5))
            .shadow(color: color(w.halo).opacity(0.9), radius: hover || selected ? 6 : 3)
            .frame(width: 22, height: 22)
            .frame(width: 26, height: 26)
            .scaleEffect(hover ? 1.12 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            .onHover { hover = $0 }
            .contentShape(Circle())
    }
}

/// A two-to-four way choice with icons.
private struct Segmented<T: Hashable>: View {
    let options: [(T, String, String)]
    @Binding var selection: T
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, icon, text in
                let on = selection == value
                Button { selection = value } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon).font(.system(size: 11))
                        if !compact { Text(text).font(.system(size: 12, weight: .medium)).fixedSize() }
                    }
                    .padding(.horizontal, compact ? 9 : 10)
                    .padding(.vertical, 5)
                    .foregroundStyle(on ? Color.black : Color.white.opacity(0.7))
                    .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(text)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selection)
    }
}

/// An on/off chip: icon and label, lit when on.
private struct Pill: View {
    let icon: String
    let text: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(on ? Color(red: 0.42, green: 0.88, blue: 0.56) : Color.white.opacity(0.18)).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .foregroundStyle(Color.white.opacity(on ? 0.92 : 0.55))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(on ? 0.1 : hover ? 0.06 : 0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

private struct FooterButton: View {
    let icon: String
    let text: String
    var danger = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(text).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(danger && hover ? Color(red: 1, green: 0.45, blue: 0.45) : Color.white.opacity(hover ? 0.95 : 0.65))
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
