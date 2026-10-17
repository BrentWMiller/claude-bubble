import AppKit
import ClaudeBubbleCore
import SwiftUI

/// What the setup window shows and can do (supplied by the app).
final class SetupModel: ObservableObject {
    @Published var connection = HookInstaller.Connection(hooks: false, statusLine: false)
    @Published var ghFound = false
    @Published var error: String?
    let palette: () -> OrbPalette
    let connect: () throws -> Void
    let revealSettings: () -> Void

    init(palette: @escaping () -> OrbPalette, connect: @escaping () throws -> Void, revealSettings: @escaping () -> Void) {
        self.palette = palette
        self.connect = connect
        self.revealSettings = revealSettings
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
    }

    /// Reads settings.json again (and looks for `gh`, off the main thread).
    func refresh() {
        let settings = (try? Data(contentsOf: Self.settingsURL)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        connection = HookInstaller.connection(settings: settings)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PRStatusFetcher.gh != nil
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
}

/// Welcome and setup: what the bubble is, one click to connect it to Claude Code, and what's connected.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    let close: () -> Void

    private static let green = Color(red: 0.42, green: 0.85, blue: 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Bubble").font(.system(size: 22, weight: .bold))
                Text("A little orb that shows what your Claude Code sessions are doing, so you can look away until one needs you.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 7) {
                let p = model.palette()
                state(.working, p, "Working", "Claude is thinking or running tools")
                state(.needs, p, "Needs you", "waiting on a permission or a question")
                state(.error, p, "Error", "a turn failed")
                state(.idle, p, "Done", "finished, ready for you")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 12) {
                check(model.connection.hooks, "Claude Code hooks",
                      "Claude Code tells the bubble when sessions start, work, need you and finish.")
                check(model.connection.statusLine, "Status line",
                      "Passes your 5-hour usage to the bubble. Your own status line keeps working as before.")
                check(model.ghFound, "GitHub CLI (optional)",
                      "Live pull request and issue status on session chips. Install with `brew install gh`, then run `gh auth login`.",
                      optional: true)
            }

            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Text("Claude Code sessions that are already running pick this up when you restart them.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack {
                Button("Show settings.json") { model.revealSettings() }
                Spacer()
                if model.connection.hooks && model.connection.statusLine {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Connect to Claude Code") { model.connectNow() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { model.refresh() }
    }

    private func state(_ s: BubbleState, _ palette: OrbPalette, _ name: String, _ what: String) -> some View {
        HStack(spacing: 10) {
            Circle().fill(s.color(in: palette)).frame(width: 9, height: 9)
                .shadow(color: s.color(in: palette).opacity(0.7), radius: 3)
            (Text(name).fontWeight(.semibold) + Text("  \(what)").foregroundColor(.secondary)).font(.system(size: 12.5))
        }
    }

    private func check(_ done: Bool, _ title: String, _ detail: String, optional: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : optional ? "circle.dashed" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(done ? Self.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(.init(detail)).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

final class SetupWindowController: NSWindowController {
    let model: SetupModel

    init(model: SetupModel) {
        self.model = model
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Claude Bubble Setup"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentViewController = NSHostingController(rootView: SetupView(model: model) { [weak window] in window?.close() })
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        model.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
