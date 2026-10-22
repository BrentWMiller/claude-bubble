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
    /// Esc closes the session list first, then the draft.
    override func cancelOperation(_ sender: Any?) {
        if model.picking { model.picking = false } else { model.cancel() }
    }

    /// Opens with `text` to edit for the session `to` (one of `targets`, which you can switch to), its top-right
    /// under `point` (where the mic was let go), on screen. `send` gets the words and the session chosen; `picked`
    /// hears a switch.
    func show(_ text: String, to session: String, among targets: [DraftTarget], talked duration: TimeInterval, at point: CGPoint,
              send: @escaping (String, String) -> Void, picked: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        model.cancel()   // one draft at a time: an open one is dropped
        model.picking = false
        model.duration = duration
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
    /// The session list is open.
    @Published var picking = false
    /// How long you talked for it.
    @Published var duration: TimeInterval = 0
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
    /// Where the session list hangs: just under the header's pill.
    private static let listTop: CGFloat = 46
    private static let rowHeight: CGFloat = 30

    var body: some View {
        // The list floats over the card (design: review speech); while it's open the window makes room below.
        ZStack(alignment: .topLeading) {
            card
            if model.picking {
                Color.black.opacity(0.001).onTapGesture { model.picking = false }   // a click off the list closes it
                sessionList.offset(x: 12, y: Self.listTop)
            }
        }
        .frame(width: DraftPanel.width, alignment: .topLeading)
        .frame(minHeight: model.picking ? Self.listTop + CGFloat(model.targets.count) * Self.rowHeight + 16 : nil,
               alignment: .top)
        .onChange(of: model.focus) { focused = true }
        .onChange(of: model.picking) { model.onResize?() }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sessionPill
                Spacer(minLength: 8)
                // How long you talked.
                Text(Self.clock(model.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tc.accent)
            }
            TextField("Say or type a message", text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.white)
                .lineLimit(2...10)
                .focused($focused)
                // Return sends (Option-Return is a new line). On macOS submit also fires when the field loses focus,
                // as a click on the session pill makes it: only a key press sends.
                .onSubmit { if NSApp.currentEvent?.type == .keyDown { model.send() } }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(focused ? 0.16 : 0.1), lineWidth: 1))
            HStack(spacing: 8) {
                Text("⌥↩ new line")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .lineLimit(1)
                    .layoutPriority(-1)   // the buttons keep their width; the hint gives way
                Spacer(minLength: 4)
                DraftButton(title: "Cancel", key: "esc", filled: false, accent: tc.accent) { model.cancel() }
                DraftButton(title: "Send", key: "↩", filled: true, accent: tc.accent) { model.send() }
            }
        }
        .padding(12)
        .frame(width: DraftPanel.width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// Which session it goes to: click to send it to another (remembered for the talk shortcut).
    private var sessionPill: some View {
        Button { model.picking.toggle() } label: {
            HStack(spacing: 7) {
                Circle().fill(tc.accent).frame(width: 8, height: 8).shadow(color: tc.accent.opacity(0.7), radius: 3)
                Text(model.chosen?.name ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1).truncationMode(.tail)
                if model.targets.count > 1 {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .rotationEffect(.degrees(model.picking ? 180 : 0))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(model.picking ? 0.1 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)   // the message keeps the keyboard
        .disabled(model.targets.count < 2)
        .help("Send to another session")
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            ForEach(model.targets) { t in
                let picked = t.id == model.target
                let c = TalkColors(t.color).accent
                Button {
                    model.pick(t.id)
                    model.picking = false
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.6), radius: 3)
                        Text(t.name).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        if picked {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(tc.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: Self.rowHeight)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(picked ? 0.08 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(DraftListRowStyle())
                .focusable(false)
            }
        }
        .padding(4)
        .frame(width: DraftPanel.width - 40)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 0x1c / 255, green: 0x1b / 255, blue: 0x22 / 255)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
    }

    /// 0:07, 1:12.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}

/// A list row that lights up under the pointer.
private struct DraftListRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Hovered(label: configuration.label) }

    private struct Hovered<Label: View>: View {
        let label: Label
        @State private var hover = false
        var body: some View {
            label
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
                .onHover { hover = $0 }
        }
    }
}

/// Cancel and Send, each with its key on a small cap (design: review speech).
private struct DraftButton: View {
    let title: String
    let key: String
    let filled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        let ink = filled ? Color(red: 0x06 / 255, green: 0x12 / 255, blue: 0x1f / 255) : Color.white.opacity(0.85)
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(key)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink.opacity(filled ? 0.75 : 0.55))
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(RoundedRectangle(cornerRadius: 4).fill(filled ? Color.black.opacity(0.14) : Color.white.opacity(0.08)))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(filled ? accent : Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(filled ? 0 : 0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
