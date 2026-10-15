import AppKit
import ClaudeBubbleCore
import SwiftUI

/// Small floating card under a hovered pip: that session's name, status and time.
final class PipCardPanel: NSPanel {
    private let host: NSHostingView<PipCardView>
    private let model: SessionsModel
    private var shownId: String?

    init(model: SessionsModel) {
        self.model = model
        host = NSHostingView(rootView: PipCardView(session: Session(id: "", state: .idle, updatedAt: Date()), model: model))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        contentView = host
    }

    override var canBecomeKey: Bool { false }

    /// Show (or refresh) the card for `session`, hanging just under the pip at `pip` (screen coordinates).
    func show(_ session: Session, under pip: CGPoint) {
        if shownId != session.id || host.rootView.session != session {
            host.rootView = PipCardView(session: session, model: model)
            shownId = session.id
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(pip) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: .zero, size: CGSize(width: 10_000, height: 10_000))
        var origin = CGPoint(x: pip.x - size.width / 2, y: pip.y - 12 - size.height)
        if origin.y < visible.minY + 8 { origin.y = pip.y + 12 }   // no room below: show above
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        setFrame(CGRect(origin: origin, size: size), display: true)
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        shownId = nil
        orderOut(nil)
    }
}
