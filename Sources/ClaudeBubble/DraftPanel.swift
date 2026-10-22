import AppKit
import ClaudeBubbleCore
import SwiftUI

/// What you said to a session, to check and edit before it goes: opens where you let go of the mic. Return sends,
/// Option-Return starts a new line, Esc or Cancel drops it. It takes the keyboard without bringing the app forward.
final class DraftPanel: NSPanel {
    static let width: CGFloat = 320
    private let model = DraftModel()
    private let host: NSHostingView<DraftView>

    init() {
        host = NSHostingView(rootView: DraftView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        super.init(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 160),
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
        contentView = host
        model.onResize = { [weak self] in self?.refit() }
    }

    // Key, so the field takes the keyboard and Esc works; never main.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { model.cancel() }

    /// Opens with `text` to edit for the session `to` (one of `targets`, which you can switch to), its top-right
    /// under `point` (where the mic was let go), on screen. `send` gets the words and the session chosen; `picked`
    /// hears a switch.
    func show(_ text: String, to session: String, among targets: [DraftTarget], at point: CGPoint,
              send: @escaping (String, String) -> Void, picked: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        model.cancel()   // one draft at a time: an open one is dropped
        model.text = text
        model.targets = targets
        model.target = session
        model.onPick = picked
        model.onSend = { [weak self] text, session in self?.orderOut(nil); send(text, session) }
        model.onCancel = { [weak self] in self?.orderOut(nil); cancel() }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: size)
        var origin = CGPoint(x: point.x - size.width + 24, y: point.y - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = point.y + 16 }   // no room below: above the pointer
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        makeKeyAndOrderFront(nil)
        model.focus += 1   // once it's key, so the field takes the cursor
    }

    /// Grows with the text, keeping its top where it is.
    private func refit() {
        guard isVisible else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard abs(size.height - frame.height) > 0.5 else { return }
        setFrame(CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

final class DraftModel: ObservableObject {
    @Published var text = "" {
        didSet { DispatchQueue.main.async { self.onResize?() } }   // after the field lays out its new line count
    }
    /// The sessions it can go to, and the one it's going to.
    @Published var targets: [DraftTarget] = []
    @Published var target = ""
    /// Bumped to put the cursor in the field.
    @Published var focus = 0
    var onSend: ((String, String) -> Void)?
    var onPick: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onResize: (() -> Void)?

    var chosen: DraftTarget? { targets.first { $0.id == target } }

    func pick(_ id: String) {
        guard id != target else { return }
        target = id
        onPick?(id)
    }

    func send() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = onSend, to = target
        clear()
        if words.isEmpty { return }
        done?(words, to)
    }

    func cancel() {
        let done = onCancel
        clear()
        done?()
    }

    private func clear() {
        onSend = nil
        onPick = nil
        onCancel = nil
    }
}

/// A session a draft can go to: its id, name, and colour as its row shows it.
struct DraftTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let color: SIMD3<Float>
}

struct DraftView: View {
    @ObservedObject var model: DraftModel
    @FocusState private var focused: Bool
    private var tc: TalkColors { TalkColors(model.chosen?.color ?? SIMD3(1, 1, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(tc.accent).frame(width: 8, height: 8).shadow(color: tc.accent.opacity(0.8), radius: 4)
                Text("To").foregroundStyle(Color.white.opacity(0.5))
                // Which session it goes to: click to send it to another (remembered for the talk shortcut).
                Menu {
                    ForEach(model.targets) { t in
                        Button { model.pick(t.id) } label: {
                            if t.id == model.target { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.chosen?.name ?? "").foregroundStyle(Color.white).fontWeight(.semibold)
                            .lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.targets.count < 2)
                .help("Send to another session")
            }
            .font(.system(size: 12))
            .lineLimit(1)
            TextField("Say or type a message", text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .lineLimit(2...10)
                .focused($focused)
                .onSubmit { model.send() }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tc.accent.opacity(focused ? 0.35 : 0.12), lineWidth: 1))
            HStack(spacing: 8) {
                Text("⏎ send · ⌥⏎ new line · esc cancel")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1)
                Spacer(minLength: 4)
                DraftButton(title: "Cancel", filled: false, accent: tc.accent) { model.cancel() }
                DraftButton(title: "Send", filled: true, accent: tc.accent) { model.send() }
            }
        }
        .padding(12)
        .frame(width: DraftPanel.width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .onChange(of: model.focus) { focused = true }
    }
}

private struct DraftButton: View {
    let title: String
    let filled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(filled ? Color(red: 0x06 / 255, green: 0x12 / 255, blue: 0x1f / 255) : Color.white.opacity(0.85))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(filled ? accent : Color.white.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
