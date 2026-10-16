import AppKit
import Combine
import ClaudeBubbleCore
import SwiftUI

/// The one floating hover card for PR and issue chips. A window of its own (not a SwiftUI popover tied to the chip's
/// view), so redrawing the session list as the card loads doesn't close it. It ignores the mouse, sitting just above
/// the chip (or below, without room), and stays put as its content grows.
final class LinkCardController {
    static let shared = LinkCardController()

    private final class Model: ObservableObject {
        @Published var link: SessionLink?
        @Published var icon = ""
        @Published var tint = Color.white
        @Published var status: (String, Color)?
    }

    private struct Content: View {
        @ObservedObject var model: Model
        @ObservedObject var previews = LinkPreviewFetcher.shared

        var body: some View {
            if let link = model.link {
                LinkPreviewCard(link: link, preview: previews.preview(for: link.url), icon: model.icon,
                                tint: model.tint, status: model.status)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
        }
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hosting: NSHostingView<Content>?
    private var anchor: NSRect = .zero   // the chip, in screen coordinates
    private var token: UUID?
    private var watch: Timer?
    private var loaded: AnyCancellable?
    private static let gap: CGFloat = 6

    /// `owner`: who asked (a chip), so a late hide from another chip doesn't close this one.
    func show(_ link: SessionLink, icon: String, tint: Color, status: (String, Color)?, from chip: NSRect, owner: UUID) {
        token = owner
        anchor = chip
        model.link = link
        model.icon = icon
        model.tint = tint
        model.status = status
        let panel = self.panel ?? makePanel()
        layout()
        panel.orderFrontRegardless()
        // The chip's view can be rebuilt under the pointer (the list redraws as things load) and never hear the
        // pointer leave, so watch for that here too.
        watch?.invalidate()
        watch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let token = self.token else { return }
            if !self.anchor.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) { self.hide(owner: token) }
        }
    }

    func hide(owner: UUID) {
        guard token == owner else { return }
        token = nil
        watch?.invalidate()
        watch = nil
        panel?.orderOut(nil)
        model.link = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let h = NSHostingView(rootView: Content(model: model))
        h.sizingOptions = [.intrinsicContentSize]
        p.contentView = h
        // The card grows when it finishes loading: re-measure once SwiftUI has the new content, keeping it on the chip.
        loaded = LinkPreviewFetcher.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layout() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.layout() }   // in case SwiftUI updated after the first look
        }
        panel = p
        hosting = h
        return p
    }

    private func layout() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        var y = anchor.maxY + Self.gap
        if y + size.height > screen.maxY { y = anchor.minY - Self.gap - size.height }
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height).integral
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

/// Finds the chip's place on screen, for the card to sit against.
struct ScreenFrameReader: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }

    static func screenRect(_ box: Box) -> NSRect? {
        guard let v = box.view, let w = v.window else { return nil }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }
}
