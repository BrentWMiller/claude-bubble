import AppKit
import ClaudeBubbleCore

/// Borderless floating panel hosting the orb; visible on every Space and drag-to-move.
final class BubblePanel: NSPanel {
    private static let originKey = "bubbleOrigin"
    private let orbView: OrbView
    private var pips: NSView!
    private var mouseMonitors: [Any] = []

    init(animator: OrbAnimator, model: SessionsModel, diameter: Double) {
        let side = OrbSize.panelSide(forDiameter: diameter)
        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: side, height: side), animator: animator)
        super.init(contentRect: NSRect(origin: Self.initialOrigin(side: side), size: NSSize(width: side, height: side)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Pips sit in the bottom margin below the orb (the orb's lowest edge is 20% up); clicks pass through them.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        orbView.autoresizingMask = [.width, .height]
        container.addSubview(orbView)
        let pips = PassthroughHostingView(rootView: PipsView(model: model))
        container.addSubview(pips)
        self.pips = pips
        contentView = container
        layoutPips()
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

    var onClick: (() -> Void)? {
        get { orbView.onClick }
        set { orbView.onClick = newValue }
    }

    var onRightClick: ((NSEvent, NSView) -> Void)? {
        get { orbView.onRightClick }
        set { orbView.onRightClick = newValue }
    }

    /// Reports moves the user made (dragging, Reset Position) — not the app's own follow/resize moves,
    /// so follow's shared spot never drifts.
    var onUserMoved: ((CGRect) -> Void)?
    /// Origin of a move the app itself started; the matching didMove is ignored.
    private var expectedOrigin: CGPoint?

    /// Move the panel without it counting as a user move.
    func move(to origin: CGPoint) {
        expectedOrigin = origin
        setFrameOrigin(origin)
    }

    func setRendering(_ on: Bool) { orbView.isPaused = !on }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        setFrameOrigin(Self.initialOrigin(side: frame.width))
    }

    /// Resize around the orb's centre, then keep the whole panel on its display.
    func setDiameter(_ diameter: Double) {
        let side = OrbSize.panelSide(forDiameter: diameter)
        guard abs(side - frame.width) > 0.5 else { return }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var target = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        if let visible = Self.screen(containing: centre)?.visibleFrame {
            target.origin = RelativePlacement.origin(for: RelativePlacement.spot(of: target, in: visible), side: side, in: visible)
        }
        expectedOrigin = target.origin
        setFrame(target, display: true)
        layoutPips()
    }

    private func layoutPips() {
        let side = frame.width
        pips.frame = NSRect(x: 0, y: side * 0.033, width: side, height: min(14, side * 0.17))
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    @objc private func didMove() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
        if let expected = expectedOrigin, abs(expected.x - frame.origin.x) < 0.5, abs(expected.y - frame.origin.y) < 0.5 {
            expectedOrigin = nil
            return
        }
        expectedOrigin = nil
        onUserMoved?(frame)
    }

    /// A display was unplugged or rearranged: pull the bubble back on screen if it was stranded.
    @objc private func screensChanged() {
        let origin = Self.placement(for: frame.origin, side: frame.width)
        if origin != frame.origin { move(to: origin) }
    }

    private static func initialOrigin(side: CGFloat) -> CGPoint {
        placement(for: UserDefaults.standard.string(forKey: originKey).map { NSPointFromString($0) }, side: side)
    }

    private static func placement(for saved: CGPoint?, side: CGFloat) -> CGPoint {
        let main = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return BubblePlacement.origin(saved: saved, size: side, screenFrames: NSScreen.screens.map(\.frame), mainVisibleFrame: main)
    }
}
