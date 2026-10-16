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
        window.setContentSize(NSSize(width: 460, height: 680))
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
        simulator.usageActive = false
        simulator.isOpen = false
    }
}

struct SimulatorView: View {
    @ObservedObject var sim: SimulatorModel
    let palette: () -> OrbPalette
    private let options: [(BubbleState, Bool, String)] = [
        (.working, false, "Work"), (.needs, false, "Needs"), (.error, false, "Error"), (.idle, false, "Done"), (.idle, true, "Review")
    ]

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
            usage
            HStack {
                Button("Play story") { sim.playStory() }.keyboardShortcut(.defaultAction)
                Button("Play session") { sim.playSession() }.help("A scripted session: every motion and layer, a permission wait, an error, and usage running down then resetting")
                Button("Reset") { sim.reset() }
                Spacer()
                Text("The orb shows these while open").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 460, height: 680)
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Simulate usage", isOn: $sim.usageActive)
                Spacer()
                Button("Reset window") { sim.resetWindow() }.disabled(!sim.usageActive)
            }
            HStack {
                Slider(value: $sim.usageLeft, in: 0...100)
                Text("\(Int(sim.usageLeft.rounded()))% left")
                    .font(.system(size: 12, design: .monospaced)).frame(width: 70, alignment: .trailing)
            }
            .disabled(!sim.usageActive)
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func row(_ s: SimulatorModel.Sim) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill((s.review ? BubbleState.needs : s.state).color(in: palette())).frame(width: 7, height: 7)
                Text(s.name).font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Button { sim.remove(s.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                ForEach(options, id: \.2) { state, review, label in
                    let tint = (review ? BubbleState.needs : state).color(in: palette())
                    if s.state == state && s.review == review {
                        Button(label) { sim.set(s.id, state, review: review) }.buttonStyle(.borderedProminent).tint(tint)
                    } else {
                        Button(label) { sim.set(s.id, state, review: review) }.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
            // The orb's motion and layers (shown while this session is working and the most recent to change).
            HStack(spacing: 6) {
                Picker("", selection: Binding(get: { s.motion }, set: { sim.setMotion(s.id, $0) })) {
                    ForEach(Motion.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Button("Tick") { sim.fire(s.id, .tick) }
                Button("Fail") { sim.fire(s.id, .fail) }
                Button("Skill") { sim.fire(s.id, .skill) }
                Stepper("Subagents \(s.subagents)", value: Binding(get: { s.subagents }, set: { sim.setSubagents(s.id, $0) }), in: 0...6)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

extension Motion {
    var label: String {
        switch self {
        case .generating: "Generating"
        case .read: "Read"
        case .search: "Search"
        case .edit: "Edit / Write"
        case .bash: "Bash"
        case .web: "Web"
        case .mcp: "MCP tool"
        case .compacting: "Compacting"
        case .waiting: "Waiting"
        }
    }
}
