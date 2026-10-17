import AppKit
import ClaudeBubbleCore
import SwiftUI

final class SimulatorWindowController: NSWindowController, NSWindowDelegate {
    private let simulator: SimulatorModel
    private let stress: StressRunner

    init(simulator: SimulatorModel, stress: StressRunner, palette: @escaping () -> OrbPalette) {
        self.simulator = simulator
        self.stress = stress
        let window = NSWindow(contentViewController: NSHostingController(rootView: SimulatorView(sim: simulator, stress: stress, palette: palette)))
        window.title = "Session Simulator"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 460, height: 860))
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
        stress.stop()
        simulator.reset()
        simulator.usageActive = false
        simulator.isOpen = false
    }
}

struct SimulatorView: View {
    @ObservedObject var sim: SimulatorModel
    @ObservedObject var stress: StressRunner
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
            stressTest
            HStack {
                Button("Play story") { sim.playStory() }.keyboardShortcut(.defaultAction)
                Button("Play session") { sim.playSession() }.help("A scripted session: every motion and layer, a permission wait, an error, and usage running down then resetting")
                Button("Reset") { sim.reset() }.disabled(stress.running)
                Spacer()
                Text("The orb shows these while open").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 460, height: 860)
    }

    // Many agents at once, and what that costs: the readout covers the last 5 seconds.
    private var stressTest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stress test").font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("Real files", isOn: $stress.writesFiles)
                    .help("Write session files like the hook does, so loading and syncing are measured too (otherwise drawing only)")
            }
            Group {
                Stepper("Sessions \(stress.sessions)", value: $stress.sessions, in: 1...50)
                Stepper("Subagents each \(stress.subagents)", value: $stress.subagents, in: 0...6)
                HStack {
                    Text("Events")
                    Slider(value: $stress.rate, in: 1...100)
                    Text("\(Int(stress.rate))/s").font(.system(size: 12, design: .monospaced)).frame(width: 50, alignment: .trailing)
                }
            }
            .disabled(stress.running)
            HStack {
                if stress.running {
                    Button("Stop") { stress.stop() }
                } else {
                    Button("Start") { stress.start() }
                }
                Button("Copy report") { stress.copyReport() }.disabled(stress.report == nil)
                Spacer()
                if stress.running || stress.elapsed > 0 {
                    Text(StressRunner.duration(stress.elapsed))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(stress.running ? .primary : .secondary)
                        .help("Run time")
                }
                if stress.running { ProgressView().controlSize(.small) }
            }
            Text(stress.report?.text ?? "Start a run to measure the main thread's work, stalls, frame rates, CPU and memory.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(stress.report == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
                .textSelection(.enabled)
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
