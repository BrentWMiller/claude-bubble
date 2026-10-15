import AppKit
import ClaudeBubbleCore

/// Borderless floating panel hosting the orb; visible on every Space and drag-to-move.
final class BubblePanel: NSPanel {
    static let side: CGFloat = 120
    private static let originKey = "bubbleOrigin"
    private let orbView: OrbView
    private var mouseMonitors: [Any] = []

    init(animator: OrbAnimator) {
        let side = Self.side
        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: side, height: side), animator: animator)
        super.init(contentRect: NSRect(origin: Self.initialOrigin(), size: NSSize(width: side, height: side)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = orbView
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startClickThrough()
    }

    /// Ignore the mouse unless it's over the orb, so the transparent margin doesn't swallow clicks.
    private func startClickThrough() {
        ignoresMouseEvents = true
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in self?.updateMouseCapture() }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.updateMouseCapture()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func updateMouseCapture() {
        let over = BubblePlacement.isOverOrb(NSEvent.mouseLocation, panelFrame: frame)
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setRendering(_ on: Bool) { orbView.isPaused = !on }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        setFrameOrigin(Self.initialOrigin())
    }

    @objc private func didMove() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    /// A display was unplugged or rearranged: pull the bubble back on screen if it was stranded.
    @objc private func screensChanged() {
        let origin = Self.placement(for: frame.origin)
        if origin != frame.origin { setFrameOrigin(origin) }
    }

    private static func initialOrigin() -> CGPoint {
        placement(for: UserDefaults.standard.string(forKey: originKey).map { NSPointFromString($0) })
    }

    private static func placement(for saved: CGPoint?) -> CGPoint {
        let main = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return BubblePlacement.origin(saved: saved, size: side, screenFrames: NSScreen.screens.map(\.frame), mainVisibleFrame: main)
    }
}
