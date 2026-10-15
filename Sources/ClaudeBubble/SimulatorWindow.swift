import AppKit
import ClaudeBubbleCore
import SwiftUI

final class SimulatorWindowController: NSWindowController, NSWindowDelegate {
    private let simulator: SimulatorModel

    init(simulator: SimulatorModel, palette: @escaping () -> OrbPalette) {
        self.simulator = simulator
        let window = NSWindow(contentViewController: NSHostingController(rootView: SimulatorView(sim: simulator, palette: palette)))
        window.title = "Session Simulator"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 400, height: 480))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        simulator.isOpen = true
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing hands the orb back to the real sessions and stops any story mid-way.
    func windowWillClose(_ notification: Notification) {
        simulator.reset()
        simulator.isOpen = false
    }
}

struct SimulatorView: View {
    @ObservedObject var sim: SimulatorModel
    let palette: () -> OrbPalette
    private let options: [(BubbleState, String)] = [(.working, "Work"), (.needs, "Needs"), (.error, "Error"), (.idle, "Done")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(sim.sessions.count) \(sim.sessions.count == 1 ? "session" : "sessions")")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("+ Add session") { sim.add() }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(sim.sessions) { s in row(s) }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button("Play story") { sim.playStory() }.keyboardShortcut(.defaultAction)
                Button("Reset") { sim.reset() }
                Spacer()
                Text("The orb shows these while open").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400, height: 480)
    }

    private func row(_ s: SimulatorModel.Sim) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(s.state.color(in: palette())).frame(width: 7, height: 7)
                Text(s.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Button { sim.remove(s.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                ForEach(options, id: \.1) { state, label in
                    if s.state == state {
                        Button(label) { sim.set(s.id, state) }.buttonStyle(.borderedProminent).tint(state.color(in: palette()))
                    } else {
                        Button(label) { sim.set(s.id, state) }.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
