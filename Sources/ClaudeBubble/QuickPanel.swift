import AppKit
import ClaudeBubbleCore
import SwiftUI

/// What the quick panel's buttons do (supplied by the app).
struct QuickPanelActions {
    /// Hides the bubble; it comes back on its own after an hour.
    var hideForAnHour: () -> Void
    var restart: () -> Void
    var quit: () -> Void
    var previewSound: (CompletionSound) -> Void
    var openSetup: () -> Void
    var disconnect: () -> Void
    var uninstall: () -> Void
    var resetPosition: () -> Void
    var launchAtLogin: () -> Bool
    var toggleLaunchAtLogin: () -> Void
    /// "live", or a forced state's raw value.
    var debugState: () -> String
    var setDebugState: (String) -> Void
    var openSimulator: () -> Void
    var installUpdate: () -> Void
    var checkForUpdates: () -> Void
    /// Shows the orb/island in the state a colour belongs to while it's being edited (nil: back to normal).
    var previewColor: (PaletteColor?) -> Void
}

/// The right-click panel: the bubble's own dark card with one-click controls, instead of a system menu.
final class QuickPanel: NSPanel {
    static let width: CGFloat = 300
    private var monitors: [Any] = []
    private let host: NSHostingView<QuickPanelView>
    private let actions: QuickPanelActions

    private let updater: Updater

    init(settings: SettingsModel, updater: Updater, actions: QuickPanelActions) {
        self.actions = actions
        self.updater = updater
        host = NSHostingView(rootView: QuickPanelView(settings: settings, updater: updater, actions: actions, close: {}))
        host.sizingOptions = [.intrinsicContentSize]   // fittingSize needs it; no min/max constraints (costly per frame)
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        host.rootView = QuickPanelView(settings: settings, updater: updater, actions: actions, close: { [weak self] in self?.dismiss() })
        host.rootView.state.onResize = { [weak self] in self?.refit() }
        contentView = host
    }

    // Key, so Esc and the shortcuts work and the controls take the keyboard; never main.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// ⌘H hide for an hour, ⌘, settings, ⌘Q quit (the hints shown on the rows).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "h": dismiss(); actions.hideForAnHour(); return true
        case ",": host.rootView.state.go(.advanced); return true
        case "q": actions.quit(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// Opens with its top-left at `point` (screen space), kept on that screen, on `page`.
    func show(at point: CGPoint, page: QuickPanelState.Page = .main) {
        host.rootView.state.page = page
        host.rootView.state.anchor = point
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: point.x + 4, y: point.y - size.height - 4)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        host.rootView.state.popIn()
        makeKeyAndOrderFront(nil)
        // A click anywhere else closes it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(m)
        }
    }

    /// The pages differ in height: keep the top-left where it opened as the content resizes.
    func refit() {
        guard isVisible else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }

    func dismiss() {
        actions.previewColor(nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        guard isVisible else { return }
        orderOut(nil)
    }
}

/// The panel's page and pop-in.
final class QuickPanelState: ObservableObject {
    enum Page { case main, advanced }
    @Published var page: Page = .main
    @Published var shown = false
    var anchor: CGPoint = .zero
    /// Called after the page changes so the window can fit it.
    var onResize: (() -> Void)?

    func popIn() {
        shown = false
        DispatchQueue.main.async { withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { self.shown = true } }
    }

    func go(_ page: Page) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.page = page }
        resized()
    }

    /// The content changed height: fit the window to it.
    func resized() { DispatchQueue.main.async { self.onResize?() } }
}

struct QuickPanelView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var updater: Updater
    let actions: QuickPanelActions
    let close: () -> Void
    @ObservedObject var state = QuickPanelState()
    @State private var hoveredTheme: String?
    /// The custom colour wells under the theme grid are open.
    @State private var editingColors = false
    /// The colour open in the editor under the wells.
    @State private var editingColor: PaletteColor?

    private var prefs: BubblePreferences { settings.prefs }
    private let dim = Color.white.opacity(0.5)

    var body: some View {
        VStack(spacing: 0) {
            // A grab handle: drag the panel anywhere (dragging its background would fight the sliders).
            ZStack {
                Capsule().fill(Color.white.opacity(0.18)).frame(width: 32, height: 4)
                WindowDragArea()
            }
            .frame(height: 14)
            .help("Drag to move")
            Group {
                if state.page == .main { mainPage.transition(.move(edge: .leading).combined(with: .opacity)) }
                else { advancedPage.transition(.move(edge: .trailing).combined(with: .opacity)) }
            }
        }
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 2)
        .frame(width: QuickPanel.width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x20 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .scaleEffect(state.shown ? 1 : 0.95, anchor: .topLeading)
        .opacity(state.shown ? 1 : 0)
        .environment(\.colorScheme, .dark)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let release = updater.available {
                UpdateRow(version: release.version.description, installing: updater.installing) { close(); actions.installUpdate() }
                    .padding(.bottom, 8)
            }
            top
            divider
            theme
            sliders
            divider
            toggles
            divider
            Row(title: "Hide for an hour", shortcut: "⌘H") { close(); actions.hideForAnHour() }
            Row(title: "Settings…", shortcut: "⌘,", chevron: true) { state.go(.advanced) }
            divider
            Row(title: "Restart") { actions.restart() }
            Row(title: "Quit Claude Bubble", shortcut: "⌘Q") { actions.quit() }
        }
    }

    // MARK: Advanced

    private var advancedPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { state.go(.main) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Settings").font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.white)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            divider
            if prefs.style == .island {
                sectionTitle("Island")
                VStack(spacing: 6) {
                    HStack {
                        Text("At rest").foregroundStyle(dim)
                        Spacer()
                        Segmented(options: [(IslandRest.live, nil, "Live"), (.compact, nil, "Compact")],
                                  selection: Binding(get: { prefs.islandRest }, set: { settings.prefs.islandRest = $0 }))
                    }
                    HStack {
                        Text("Glow").foregroundStyle(dim)
                        Spacer()
                        Segmented(options: [(IslandGlow.waves, nil, "Waves"), (.none, nil, "None")],
                                  selection: Binding(get: { prefs.islandGlow }, set: { settings.prefs.islandGlow = $0 }))
                    }
                }
                .font(.system(size: 13))
                divider
            }
            sectionTitle("General")
            VStack(spacing: 6) {
                toggleRow("Launch at login", Binding(get: { actions.launchAtLogin() }, set: { _ in actions.toggleLaunchAtLogin() }))
                toggleRow("Check for updates automatically", Binding(get: { updater.checksAutomatically },
                                                                     set: { updater.checksAutomatically = $0 }))
            }
            divider
            Row(title: "Check for updates…") { close(); actions.checkForUpdates() }
            Row(title: "Setup…") { close(); actions.openSetup() }
            Row(title: "Reset position") { actions.resetPosition() }
            divider
            sectionTitle("Debug")
            Segmented(options: [("live", nil, "Live"), ("idle", nil, "Idle"), ("working", nil, "Work"), ("needs", nil, "Needs"),
                                ("error", nil, "Error")],
                      selection: Binding(get: { actions.debugState() }, set: { actions.setDebugState($0) }), fill: true)
            Row(title: "Session Simulator…") { close(); actions.openSimulator() }
                .padding(.top, 4)
            divider
            Row(title: "Disconnect from Claude Code…") { close(); actions.disconnect() }
            Row(title: "Uninstall Claude Bubble…", destructive: true) { close(); actions.uninstall() }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(dim).padding(.bottom, 6)
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 8)
    }

    // MARK: Orb / Island / Quiet, and the dock

    private enum Mode: Hashable { case orb, island, quiet }

    private var top: some View {
        VStack(spacing: 10) {
            Segmented(options: [(Mode.orb, nil, "Orb"), (.island, nil, "Island"), (.quiet, nil, "Quiet")],
                      selection: Binding(get: { prefs.quiet ? .quiet : prefs.style == .island ? .island : .orb },
                                         set: { mode in
                                             var p = settings.prefs
                                             switch mode {
                                             case .orb: p.style = .orb; p.quiet = false
                                             case .island: p.style = .island; p.quiet = false
                                             case .quiet: p.quiet = true
                                             }
                                             settings.prefs = p
                                         }),
                      fill: true, large: true)
            if prefs.style == .island {
                HStack {
                    Text("Dock").foregroundStyle(dim)
                    Spacer()
                    Segmented(options: IslandDock.allCases.map { ($0, icon(for: $0), $0.rawValue.capitalized) },
                              selection: Binding(get: { prefs.islandDock }, set: { settings.prefs.islandDock = $0 }))
                }
                .font(.system(size: 13))
            }
        }
    }

    private func icon(for dock: IslandDock) -> String {
        switch dock {
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        case .left: "arrow.left.to.line"
        case .right: "arrow.right.to.line"
        }
    }

    // MARK: Theme

    private var theme: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Theme").foregroundStyle(dim)
                Spacer()
                Text(hoveredTheme ?? (prefs.customized ? "Custom" : prefs.presetName)).foregroundStyle(Color.white)
                if prefs.customized {
                    Button("Reset") { settings.applyPreset(prefs.presetName) }
                        .buttonStyle(.plain)
                        .foregroundStyle(dim)
                        .help("Back to \(prefs.presetName)")
                }
            }
            .font(.system(size: 13))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), alignment: .leading, spacing: 10) {
                ForEach(OrbPalette.presets, id: \.name) { preset in
                    ThemeSwatch(palette: preset.palette, selected: !prefs.customized && prefs.presetName == preset.name)
                        .onHover { hoveredTheme = $0 ? preset.name : (hoveredTheme == preset.name ? nil : hoveredTheme) }
                        .onTapGesture { settings.applyPreset(preset.name) }
                        .help(preset.name)
                }
                CustomSwatch(palette: prefs.palette, selected: prefs.customized, open: editingColors)
                    .onHover { hoveredTheme = $0 ? "Custom" : (hoveredTheme == "Custom" ? nil : hoveredTheme) }
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            editingColors.toggle()
                            if !editingColors { editingColor = nil }
                        }
                        state.resized()
                    }
                    .help("Custom colours")
            }
            if editingColors {
                VStack(spacing: 10) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                        ForEach(PaletteColor.allCases, id: \.self) { c in
                            ColorWell(rgb: prefs.palette[c], label: c.label, selected: editingColor == c)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                        editingColor = editingColor == c ? nil : c
                                    }
                                    state.resized()
                                }
                        }
                    }
                    // Edits apply as you drag, with the orb (or island) showing that colour's state: it's the preview.
                    if let c = editingColor {
                        ColorEditor(rgb: Binding(get: { prefs.palette[c] }, set: { settings.setColor($0, for: c) }))
                            .id(c)
                            .transition(.opacity)
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: editingColor) { _, color in actions.previewColor(color) }
    }

    // MARK: Size, opacity, pointer

    private var sliders: some View {
        VStack(spacing: 12) {
            sliderRow("Size", value: Binding(get: { prefs.diameter }, set: { settings.prefs.diameter = $0.rounded() }),
                      range: OrbSize.minDiameter...OrbSize.maxDiameter, text: "\(Int(prefs.diameter))pt")
            sliderRow("Opacity", value: Binding(get: { prefs.opacity }, set: { settings.prefs.opacity = $0 }),
                      range: 0.3...1, text: "\(Int((prefs.opacity * 100).rounded()))%")
            HStack {
                Text("Pointer").foregroundStyle(dim)
                Spacer()
                Segmented(options: [(PointerMode.off, nil, "Off"), (.watch, nil, "Watch"), (.follow, nil, "Follow")],
                          selection: Binding(get: { pointerMode }, set: setPointer))
            }
            .font(.system(size: 13))
        }
        .padding(.top, 14)
    }

    /// Off: the orb ignores the pointer. Watch: it turns its attention to it. Follow: and it hops to the pointer's display.
    private enum PointerMode: Hashable { case off, watch, follow }

    private var pointerMode: PointerMode {
        prefs.followPointer ? .follow : prefs.interaction == .off ? .off : .watch
    }

    private func setPointer(_ mode: PointerMode) {
        settings.prefs.interaction = mode == .off ? .off : .attention
        settings.setFollowPointer(mode == .follow)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(dim).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small).tint(.white)
            Text(text).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.75)).frame(width: 44, alignment: .trailing)
        }
        .font(.system(size: 13))
    }

    // MARK: Toggles

    private var toggles: some View {
        VStack(spacing: 6) {
            toggleRow("Toasts", Binding(get: { prefs.toasts }, set: { settings.prefs.toasts = $0 }))
            toggleRow("Usage meter", Binding(get: { prefs.usage }, set: { settings.prefs.usage = $0 }))
            toggleRow("Edge light", Binding(get: { prefs.edgeLight }, set: { settings.prefs.edgeLight = $0 }))
            toggleRow("Approve from the bubble", Binding(get: { prefs.approvals }, set: { settings.prefs.approvals = $0 }))
            toggleRow("Sounds", Binding(get: { prefs.sounds }, set: { settings.prefs.sounds = $0 }))
            HStack(spacing: 8) {
                Text("Finish sound").foregroundStyle(dim)
                Spacer()
                Menu {
                    ForEach(CompletionSound.allCases, id: \.self) { option in
                        Button(option.label) {
                            settings.prefs.completionSound = option
                            actions.previewSound(option)
                        }
                    }
                } label: {
                    Text(prefs.completionSound.label).foregroundStyle(Color.white)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { actions.previewSound(prefs.completionSound) } label: { Image(systemName: "play.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .help("Preview")
            }
            .font(.system(size: 13))
            .padding(.top, 2)
        }
    }

    private func toggleRow(_ title: String, _ on: Binding<Bool>) -> some View {
        HStack {
            Text(title).foregroundStyle(Color.white.opacity(0.9))
            Spacer()
            Toggle("", isOn: on).toggleStyle(.switch).controlSize(.small).tint(Color(red: 0.2, green: 0.78, blue: 0.35)).labelsHidden()
        }
        .font(.system(size: 13))
    }
}

/// Moves its window when dragged (the system's own window drag), with an open-hand cursor over it.
private struct WindowDragArea: NSViewRepresentable {
    final class Area: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> Area { Area() }
    func updateNSView(_ nsView: Area, context: Context) {}
}

/// One editable colour: a well with its name under it, ringed while it's open in the editor.
private struct ColorWell: View {
    let rgb: SIMD3<Float>
    let label: String
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                .frame(height: 22)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(selected ? 1 : hover ? 0.45 : 0), lineWidth: 2)
                    .padding(-3))
            Text(label).font(.system(size: 11)).foregroundStyle(Color.white.opacity(selected ? 0.95 : 0.5))
        }
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// A small colour picker that lives in the panel (the system colour panel would take focus and close it): a
/// saturation/brightness square, a hue bar and a hex field. Every change is applied straight away.
private struct ColorEditor: View {
    @Binding var rgb: SIMD3<Float>
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hex = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let size = geo.size
                ZStack(alignment: .topLeading) {
                    Color(hue: hue, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                    knob(Color(hue: hue, saturation: saturation, brightness: brightness))
                        .position(x: saturation * size.width, y: (1 - brightness) * size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    saturation = min(max(g.location.x / size.width, 0), 1)
                    brightness = 1 - min(max(g.location.y / size.height, 0), 1)
                    apply()
                })
            }
            .frame(height: 96)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: stride(from: 0.0, through: 1, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                    knob(Color(hue: hue, saturation: 1, brightness: 1))
                        .position(x: hue * geo.size.width, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    hue = min(max(g.location.x / geo.size.width, 0), 0.9999)
                    apply()
                })
            }
            .frame(height: 12)
            HStack(spacing: 8) {
                Circle().fill(Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))).frame(width: 14, height: 14)
                TextField("#RRGGBB", text: $hex)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($typing)
                    .onSubmit(applyHex)
                    .onChange(of: typing) { _, on in if !on { applyHex() } }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        }
        .onAppear(perform: load)
    }

    private func knob(_ fill: Color) -> some View {
        Circle().fill(fill)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 2)
            .frame(width: 12, height: 12)
    }

    /// Picks up the current colour (keeping the hue of a grey, which has none of its own).
    private func load() {
        let c = NSColor(srgbRed: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
        if c.saturationComponent > 0.001 { hue = c.hueComponent }
        saturation = c.saturationComponent
        brightness = c.brightnessComponent
        hex = Self.hex(rgb)
    }

    private func apply() {
        guard let c = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1).usingColorSpace(.sRGB) else { return }
        rgb = [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)]
        if !typing { hex = Self.hex(rgb) }
    }

    private func applyHex() {
        let digits = hex.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { hex = Self.hex(rgb); return }
        rgb = [Float((v >> 16) & 0xff) / 255, Float((v >> 8) & 0xff) / 255, Float(v & 0xff) / 255]
        load()
    }

    static func hex(_ c: SIMD3<Float>) -> String {
        String(format: "#%02X%02X%02X", Int((c.x * 255).rounded()), Int((c.y * 255).rounded()), Int((c.z * 255).rounded()))
    }
}

/// The theme grid's last spot: your own colours (a dashed ring with a plus until you pick some).
private struct CustomSwatch: View {
    let palette: OrbPalette
    let selected: Bool
    let open: Bool
    @State private var hover = false

    private func color(_ c: SIMD3<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }

    var body: some View {
        let w = palette.working
        ZStack {
            if selected {
                Circle().fill(AngularGradient(colors: [color(w.c1), color(w.c2), color(w.c3), color(w.c1)], center: .center))
            } else {
                Circle().strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
            }
            Image(systemName: open ? "chevron.up" : selected ? "slider.horizontal.3" : "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(selected ? 0.9 : 0.6))
                .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 1)
        }
        .overlay(Circle().stroke(Color.white.opacity(selected ? 1 : hover ? 0.45 : 0), lineWidth: 2).padding(-3.5))
        .frame(width: 22, height: 22)
        .frame(width: 30, height: 30)
        .scaleEffect(hover && !selected ? 1.1 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
        .onHover { hover = $0 }
        .contentShape(Circle())
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
            .overlay(Circle().stroke(Color.white.opacity(selected ? 1 : hover ? 0.45 : 0), lineWidth: 2).padding(-3.5))
            .frame(width: 22, height: 22)
            .frame(width: 30, height: 30)
            .scaleEffect(hover && !selected ? 1.1 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hover)
            .onHover { hover = $0 }
            .contentShape(Circle())
    }
}

/// A segmented choice: text or icons, the selected one a white chip.
private struct Segmented<T: Hashable>: View {
    let options: [(T, String?, String)]
    @Binding var selection: T
    var fill = false
    var large = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, icon, text in
                let on = selection == value
                Button { selection = value } label: {
                    Group {
                        if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                        else { Text(text).font(.system(size: large ? 14 : 13, weight: .medium)).fixedSize() }
                    }
                    .frame(maxWidth: fill ? .infinity : nil)
                    .padding(.horizontal, fill ? 4 : icon == nil ? 12 : 10)
                    .padding(.vertical, large ? 7 : 5)
                    .foregroundStyle(on ? Color.black : Color.white.opacity(0.8))
                    .background(RoundedRectangle(cornerRadius: large ? 8 : 6).fill(on ? Color.white : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(text)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: large ? 10 : 8).fill(Color.white.opacity(0.08)))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: selection)
    }
}

/// A plain menu row with an optional shortcut hint, highlighted on hover.
private struct Row: View {
    let title: String
    var shortcut: String?
    var chevron = false
    var destructive = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(destructive ? Color(red: 1, green: 0.45, blue: 0.45) : Color.white.opacity(0.92))
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(Color.white.opacity(0.4)) }
                if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.4)) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hover = $0 }
    }
}

/// "Update to 0.1.3" at the top of the panel while a newer version is out.
private struct UpdateRow: View {
    let version: String
    let installing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.42, green: 0.85, blue: 0.55))
                Text(installing ? "Downloading \(version)…" : "Update to \(version)").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                Spacer()
                if !installing { Text("Install").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.5)) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.42, green: 0.85, blue: 0.55).opacity(hover ? 0.2 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 0.42, green: 0.85, blue: 0.55).opacity(0.3), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(installing)
        .onHover { hover = $0 }
    }
}
