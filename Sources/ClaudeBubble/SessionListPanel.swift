import AppKit
import ClaudeBubbleCore
import Combine
import SwiftUI

/// Floating session list shown while hovering the orb.
final class SessionListPanel: NSPanel {
    private let host: FirstMouseHostingView<SessionListView>
    private var bubbleFrame: CGRect = .zero
    private var subscription: AnyCancellable?

    init(model: SessionsModel, onSelect: @escaping () -> Void) {
        host = FirstMouseHostingView(rootView: SessionListView(model: model, onSelect: onSelect))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        contentView = host
        // Rows come and go while the list is open; refit and re-anchor.
        subscription = model.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.show(near: self.bubbleFrame)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Re-anchor after the orb has moved (flip above/below, stay on screen). While it's being dragged the list
    /// rides along as a child window, so the window server moves both together, perfectly smoothly.
    func follow(_ bubbleFrame: CGRect) {
        guard isVisible, bubbleFrame != self.bubbleFrame else { return }
        show(near: bubbleFrame)
    }

    /// The orb's panel; the list is attached to it as a child window while open.
    weak var bubble: NSWindow?

    override func orderOut(_ sender: Any?) {
        bubble?.removeChildWindow(self)
        super.orderOut(sender)
    }

    func show(near bubbleFrame: CGRect) {
        self.bubbleFrame = bubbleFrame
        host.layoutSubtreeIfNeeded()
        let center = CGPoint(x: bubbleFrame.midX, y: bubbleFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? bubbleFrame.insetBy(dx: -1000, dy: -1000)
        let frame = SessionListPlacement.frame(listSize: host.fittingSize,
                                               orbRect: SessionListPlacement.orbRect(panelFrame: bubbleFrame),
                                               visibleFrame: visible)
        setFrame(frame, display: true)
        if !isVisible { orderFrontRegardless() }
        if parent == nil { bubble?.addChildWindow(self, ordered: .above) }
    }
}
