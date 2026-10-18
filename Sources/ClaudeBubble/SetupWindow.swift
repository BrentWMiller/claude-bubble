import AppKit
import ClaudeBubbleCore
import ServiceManagement
import SwiftUI

/// What the setup window shows and can do (supplied by the app).
final class SetupModel: ObservableObject {
    @Published var connection = HookInstaller.Connection(hooks: false, statusLine: false)
    @Published var ghFound = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var error: String?
    let settings: SettingsModel
    let connect: () throws -> Void
    let toggleLaunchAtLogin: () -> Void
    let revealSettings: () -> Void
    /// The real bubble acts out a sample session while setup is open (the Session Simulator's story).
    let demo: (Bool) -> Void
    let simulator: SimulatorModel

    init(settings: SettingsModel, simulator: SimulatorModel, connect: @escaping () throws -> Void, toggleLaunchAtLogin: @escaping () -> Void,
         revealSettings: @escaping () -> Void, demo: @escaping (Bool) -> Void) {
        self.settings = settings
        self.simulator = simulator
        self.demo = demo
        self.connect = connect
        self.toggleLaunchAtLogin = toggleLaunchAtLogin
        self.revealSettings = revealSettings
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
    }

    var connected: Bool { connection.hooks && connection.statusLine }

    /// Reads settings.json and the login item again (and looks for `gh`, off the main thread).
    func refresh() {
        let settings = (try? Data(contentsOf: Self.settingsURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        connection = HookInstaller.connection(settings: settings)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PRStatusFetcher.resolveGH() != nil
            DispatchQueue.main.async { self.ghFound = found }
        }
    }

    func connectNow() {
        do {
            try connect()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard on != launchAtLogin else { return }
        toggleLaunchAtLogin()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Setup view

/// Welcome and setup: a live preview of the orb's states, how to show it, and what's connected.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsModel
    let close: () -> Void
    @Environment(\.isSnapshot) private var snapshot

    private static let green = Color(red: 0.42, green: 0.85, blue: 0.55)
    private static let amber = Color(red: 1, green: 0.78, blue: 0.35)
    private static let card = Color.white.opacity(0.05)
    private static let line = Color.white.opacity(0.08)
    private static let dim = Color.white.opacity(0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                Text("Claude Bubble").font(.system(size: 24, weight: .bold))
                Text("A little orb that shows what your Claude Code sessions are doing, so you can look away until one needs you.")
                    .font(.system(size: 13.5)).foregroundStyle(Self.dim).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)

            DemoBanner(sim: model.simulator, palette: settings.prefs.palette, island: settings.prefs.style == .island)
                .padding(.bottom, 22)

            section("Preferences")
            card {
                row(title: "Show as", detail: settings.prefs.style == .island
                    ? "Docked at a screen edge, out of the way" : "A floating orb you can place anywhere") {
                    StylePicker(selection: Binding(get: { settings.prefs.style }, set: { settings.prefs.style = $0 }))
                }
                divider
                row(title: "Launch at login", detail: "Start Claude Bubble when you log in to your Mac") {
                    if snapshot {   // the native switch can't draw offscreen
                        Capsule().fill(model.launchAtLogin ? Self.green : Color.white.opacity(0.18)).frame(width: 38, height: 22)
                            .overlay(Circle().fill(.white).padding(2), alignment: model.launchAtLogin ? .trailing : .leading)
                    } else {
                        Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                            .toggleStyle(.switch).labelsHidden().tint(Self.green)
                    }
                }
            }
            .padding(.bottom, 22)

            section("Connections")
            card {
                row(title: "Claude Code hooks", detail: "Claude Code tells the bubble when sessions start, work, need you and finish.") {
                    status(model.connection.hooks)
                }
                divider
                row(title: "Status line", detail: "Passes your 5-hour usage to the bubble. Your own status line keeps working as before.") {
                    status(model.connection.statusLine)
                }
                divider
                VStack(alignment: .leading, spacing: 10) {
                    row(title: "GitHub CLI", detail: "Live pull request and issue status on session chips.", padded: false) {
                        if model.ghFound { badge("Found", Self.green) } else { badge("Optional", Color.white.opacity(0.45)) }
                    }
                    if !model.ghFound {
                        HStack(spacing: 8) {
                            CopyCommand(command: "brew install gh")
                            CopyCommand(command: "gh auth login")
                        }
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 13)
            }

            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            Text("Claude Code sessions that are already running pick this up when you restart them.")
                .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.4))
                .padding(.top, 12).padding(.horizontal, 4)

            HStack {
                Button("Show settings.json") { model.revealSettings() }
                    .buttonStyle(PillButton(primary: false))
                Spacer()
                if model.connected {
                    Button("Done") { close() }.buttonStyle(PillButton(primary: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Connect to Claude Code") { model.connectNow() }
                        .buttonStyle(PillButton(primary: true)).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 24)
        .frame(width: 520)
        .background(Color(red: 0.13, green: 0.13, blue: 0.145))
        .environment(\.colorScheme, .dark)
        .onAppear { model.refresh() }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Color.white.opacity(0.45)).padding(.leading, 4).padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Self.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Self.line, lineWidth: 1))
    }

    private var divider: some View { Rectangle().fill(Self.line).frame(height: 1) }

    private func row<Trailing: View>(title: String, detail: String, padded: Bool = true,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Self.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, padded ? 15 : 0).padding(.vertical, padded ? 13 : 0)
    }

    private func status(_ ok: Bool) -> some View {
        ok ? badge("Connected", Self.green) : badge("Not set up", Self.amber)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(color)
        }
        .fixedSize()
    }
}

/// "Now playing" for the sample session the real bubble is acting out: its steps as a segmented bar, over the
/// island's glow, with a border that sweeps around in the state's colour.
private struct DemoBanner: View {
    @ObservedObject var sim: SimulatorModel
    let palette: OrbPalette
    let island: Bool
    /// The island's own glow (pixel dots, dot-wave, edge light), fed the demo's state as the app feeds the island.
    @StateObject private var glow = IslandModel()
    @State private var lastTicks = 0

    private var lead: SimulatorModel.Sim? { sim.sessions.first }
    private var state: BubbleState { lead?.state ?? .idle }

    private var color: Color {
        state == .idle ? Color(red: 0.47, green: 0.9, blue: 0.67) : state.color(in: palette)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let total = SimulatorModel.storyLength * sim.storyScale
            let elapsed = sim.storyStarted.map { min(context.date.timeIntervalSince($0), total) } ?? 0
            let pulse = 0.5 + 0.5 * sin(t * 3.2)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.red.opacity(0.35 * pulse)).frame(width: 14, height: 14)
                        Circle().fill(Color(red: 1, green: 0.32, blue: 0.32)).frame(width: 7, height: 7)
                    }
                    Text("LIVE PREVIEW").font(.system(size: 10.5, weight: .bold)).tracking(1.2)
                        .foregroundStyle(Color.white.opacity(0.7))
                    Text("· watch your \(island ? "dock" : "bubble")").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.4))
                    Spacer()
                    Text("\(Self.clock(elapsed)) / \(Self.clock(total))")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white.opacity(0.45))
                }
                // The story's steps, each as long as it plays: done ones lit, the current one filling.
                GeometryReader { g in
                    let steps = SimulatorStory.session.map { $0.duration * sim.storyScale }
                    let gap: CGFloat = 3
                    let usable = g.size.width - gap * CGFloat(max(steps.count - 1, 0))
                    HStack(spacing: gap) {
                        ForEach(steps.indices, id: \.self) { i in
                            let start = steps[..<i].reduce(0, +)
                            let fill = min(max((elapsed - start) / steps[i], 0), 1)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1))
                                Capsule().fill(color)
                                    .frame(width: max(0, usable * CGFloat(steps[i] / total) * CGFloat(fill)))
                                    .shadow(color: color.opacity(fill > 0 ? 0.7 : 0), radius: 3)
                            }
                            .frame(width: usable * CGFloat(steps[i] / total))
                        }
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background {
                GeometryReader { g in
                    ZStack {
                        Color.black
                        IslandGlowView(model: glow, palette: palette, orbCentre: CGPoint(x: 26, y: g.size.height / 2),
                                       waves: true, edge: false)
                        // Keeps the text readable over the brightest glow, as the island's scrim does.
                        LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .overlay {
                // A light sweeping round the border.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AngularGradient(colors: [color.opacity(0.05), color.opacity(0.9), color.opacity(0.05), color.opacity(0.05)],
                                                  center: .center, angle: .degrees(t * 70)), lineWidth: 1.2)
            }
            .animation(.easeInOut(duration: 0.6), value: state)
        }
        .onAppear { follow() }
        .onChange(of: sim.sessions) { follow() }
    }

    /// The island's glow follows the demo as the app makes the island follow the orb: its state and pace, the colour
    /// fanning over on a change, and a brighter wave for each tool that finishes.
    private func follow() {
        glow.glow = .waves
        if glow.state != state { glow.state = state }
        let key = IslandColorKey(state: state, done: state == .idle && lead != nil)
        if key != glow.colorKey {
            glow.fanFrom = glow.colorKey
            glow.fanStart = CACurrentMediaTime()
            glow.colorKey = key
        }
        let ticks = lead?.ticks ?? 0
        if ticks > lastTicks { glow.ticks = glow.ticks.filter { CACurrentMediaTime() - $0 < 0.6 } + [CACurrentMediaTime()] }
        lastTicks = ticks
    }

    static func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// Orb | Island, white thumb on the selected one.
private struct StylePicker: View {
    @Binding var selection: BubbleStyle

    var body: some View {
        HStack(spacing: 2) {
            ForEach([(BubbleStyle.orb, "Orb"), (.island, "Dock")], id: \.0) { style, name in
                Button { selection = style } label: {
                    Text(name).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(selection == style ? Color.black : Color.white.opacity(0.75))
                        .padding(.horizontal, 14).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selection == style ? Color.white : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// A shell command with a Copy button.
private struct CopyCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            HStack(spacing: 8) {
                Text(command).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.white.opacity(0.85))
                Text(copied ? "Copied" : "Copy").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.45))
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.35)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PillButton: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(primary ? Color(red: 0.2, green: 0.5, blue: 1) : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

final class SetupWindowController: NSWindowController, NSWindowDelegate {
    let model: SetupModel

    init(model: SetupModel) {
        self.model = model
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 1)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: SetupView(model: model, settings: model.settings) {
            [weak window] in window?.close()
        })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        model.refresh()
        model.demo(true)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing hands the bubble back to the real sessions.
    func windowWillClose(_ notification: Notification) { model.demo(false) }
}
