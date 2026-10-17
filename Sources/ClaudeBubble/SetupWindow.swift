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

    init(settings: SettingsModel, connect: @escaping () throws -> Void, toggleLaunchAtLogin: @escaping () -> Void,
         revealSettings: @escaping () -> Void) {
        self.settings = settings
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

// MARK: - Preview

/// The live preview at the top of setup: the app's real orb, or its real island fed simulated sessions (as the
/// Session Simulator does), cycling through the states so you know what each looks like.
final class SetupPreviewModel: ObservableObject {
    static let states: [(BubbleState, String, String)] = [
        (.working, "Working", "Claude is thinking or running tools"),
        (.needs, "Needs you", "Waiting on a permission or a question"),
        (.error, "Error", "A turn failed"),
        (.idle, "Done", "Finished and ready for you"),
    ]
    @Published var index = 0
    /// One animator per view: each Metal view steps its animator as it draws.
    let orbAnimator: OrbAnimator
    let islandAnimator: OrbAnimator
    let island = IslandModel()
    let sessions = SessionsModel()
    private(set) lazy var islandOrb: OrbView = {
        let v = OrbView(frame: NSRect(x: 0, y: 0, width: IslandLayout.orbSize, height: IslandLayout.orbSize), animator: islandAnimator)
        v.allowsDrag = false
        v.passesMouseThrough = true
        v.crisp = true
        v.preferredFramesPerSecond = 30
        return v
    }()
    private var timer: Timer?
    private var doneAt: Date?

    init(palette: OrbPalette) {
        orbAnimator = OrbAnimator(state: Self.states[0].0, palette: palette)
        islandAnimator = OrbAnimator(state: Self.states[0].0, palette: palette)
        sessions.palette = palette
        island.dock = .top
        island.glow = .waves
        island.rest = .live
        apply(previous: nil)
    }

    var current: (BubbleState, String, String) { Self.states[index] }

    func setPalette(_ palette: OrbPalette) {
        orbAnimator.palette = palette
        islandAnimator.palette = palette
        sessions.palette = palette
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3.4, repeats: true) { [weak self] _ in self?.advance() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func advance() {
        let before = current.0
        index = (index + 1) % Self.states.count
        apply(previous: before)
    }

    /// Puts both views in the current state the way the app does: the orb's state (with the finish flourish into
    /// Done), simulated sessions, the island's mode from them, and its glow colour fanning over.
    private func apply(previous: BubbleState?) {
        let state = current.0, now = Date()
        for a in [orbAnimator, islandAnimator] {
            a.setState(state)
            if previous != nil, state == .idle { a.celebrate(from: .working) }
        }
        doneAt = state == .idle && previous != nil ? now : nil
        var lead = Session(id: "sim-lead", state: state, updatedAt: now, project: "billing",
                           detail: SimulatorStory.detail(for: state), stateSince: now, title: "Billing: CSV import")
        lead.activity = SessionActivity(motion: state == .working ? .bash : .generating, since: now)
        let other = Session(id: "sim-docs", state: .idle, updatedAt: now.addingTimeInterval(-600), project: "docs",
                            detail: "Completed", stateSince: now.addingTimeInterval(-600), title: "Docs: getting started")
        sessions.sessions = [lead, other]
        island.mode = IslandMode.choose(sessions: sessions.sessions, now: now, hovering: false, doneAt: doneAt)
        island.state = state
        let key = IslandColorKey(state: state, done: island.mode == .done)
        if key != island.colorKey {
            island.fanFrom = island.colorKey
            island.fanStart = CACurrentMediaTime()
            island.colorKey = key
        }
    }
}

/// An OrbView for SwiftUI.
private struct OrbPreview: NSViewRepresentable {
    let animator: OrbAnimator
    let side: CGFloat
    var crisp = false

    func makeNSView(context: Context) -> OrbView {
        let v = OrbView(frame: NSRect(x: 0, y: 0, width: side, height: side), animator: animator)
        v.allowsDrag = false
        v.passesMouseThrough = true
        v.crisp = crisp
        return v
    }

    func updateNSView(_ nsView: OrbView, context: Context) {}
}

// MARK: - Setup view

/// Welcome and setup: a live preview of the orb's states, how to show it, and what's connected.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var preview: SetupPreviewModel
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

            previewCard.padding(.bottom, 22)

            section("Preferences")
            card {
                row(title: "Show as", detail: settings.prefs.style == .island
                    ? "Docked at a screen edge, out of the way" : "A floating orb you can place anywhere") {
                    StylePicker(selection: Binding(get: { settings.prefs.style }, set: { settings.prefs.style = $0 }))
                }
                divider
                row(title: "Launch at login", detail: "Start Claude Bubble when you log in to your Mac") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).labelsHidden().tint(Self.green)
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
        .onAppear { model.refresh(); preview.start() }
        .onDisappear { preview.stop() }
    }

    // The orb (or island) going through its states.
    private var previewCard: some View {
        let (state, name, what) = preview.current
        let color = state.color(in: settings.prefs.palette)
        return VStack(spacing: 0) {
            ZStack {
                if settings.prefs.style == .island {
                    // The real island, docked to the top of the card as it would be under the menu bar.
                    IslandView(model: preview.island, sessions: preview.sessions, orb: preview.islandOrb)
                        .frame(width: IslandLayout.windowSize.width, height: 170)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    orb(state, side: 150)
                }
            }
            .frame(height: 170)
            .animation(.easeInOut(duration: 0.25), value: settings.prefs.style)
            VStack(spacing: 4) {
                Text(name).font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                Text(what).font(.system(size: 13)).foregroundStyle(Self.dim)
            }
            .id(preview.index)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: preview.index)
        }
        .padding(.top, 14).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.07), Color(white: 0.035)], startPoint: .top, endPoint: .bottom)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Self.line, lineWidth: 1))
    }

    /// The live orb, or (rendered offscreen, where Metal views can't draw) a still of it.
    @ViewBuilder private func orb(_ state: BubbleState, side: CGFloat, crisp: Bool = false) -> some View {
        if snapshot, let image = OrbSnapshot.render(state: state, size: Int(side * 2), palette: settings.prefs.palette) {
            Image(decorative: image, scale: 2).frame(width: side, height: side)
        } else {
            OrbPreview(animator: preview.orbAnimator, side: side, crisp: crisp).frame(width: side, height: side)
        }
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

/// Orb | Island, white thumb on the selected one.
private struct StylePicker: View {
    @Binding var selection: BubbleStyle

    var body: some View {
        HStack(spacing: 2) {
            ForEach([(BubbleStyle.orb, "Orb"), (.island, "Island")], id: \.0) { style, name in
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

final class SetupWindowController: NSWindowController {
    let model: SetupModel
    private let preview: SetupPreviewModel

    init(model: SetupModel) {
        self.model = model
        preview = SetupPreviewModel(palette: model.settings.prefs.palette)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.145, alpha: 1)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SetupView(model: model, preview: preview, settings: model.settings) {
            [weak window] in window?.close()
        })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        model.refresh()
        preview.setPalette(model.settings.prefs.palette)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
