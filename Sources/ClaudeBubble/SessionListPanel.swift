import AppKit
import ClaudeBubbleCore
import Combine
import SwiftUI

/// Floating session list shown while hovering the orb.
final class SessionListPanel: NSPanel {
    private let host: FirstMouseHostingView<SessionListView>
    private let motion: CardMotionModel
    private var bubbleFrame: CGRect = .zero
    private var subscription: AnyCancellable?

    init(model: SessionsModel, onSelect: @escaping () -> Void) {
        let motion = CardMotionModel()
        self.motion = motion
        host = FirstMouseHostingView(rootView: SessionListView(model: model, motion: motion, onSelect: onSelect))
        host.sizingOptions = [.intrinsicContentSize]   // fittingSize needs it; no min/max constraints (costly per frame)
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

    /// Open (and not on its way out).
    var isShown: Bool { isVisible && motion.hiddenAt == nil }

    /// Pop out: slip back toward the orb and close, then hide the window once the animation is done.
    func popOut() {
        guard isShown else { return }
        let at = CACurrentMediaTime()
        motion.hiddenAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + CardMotion.hideDuration + 0.02) { [weak self] in
            guard let self, self.motion.hiddenAt == at else { return }   // re-opened meanwhile
            self.orderOut(nil)
        }
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
        motion.fromTop = frame.midY < bubbleFrame.midY   // hanging below the orb: unfold from the top edge
        if !isShown {
            motion.shownAt = CACurrentMediaTime()   // pop in (again, if it was closing)
            motion.hiddenAt = nil
        }
        setFrame(frame, display: true)
        if !isVisible { orderFrontRegardless() }
        if parent == nil { bubble?.addChildWindow(self, ordered: .above) }
    }
}
