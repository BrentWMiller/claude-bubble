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
        // Pips sit on an arc under the orb (see ArcPipsView); clicks pass through, hover is computed from pointer math.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        orbView.autoresizingMask = [.width, .height]
        container.addSubview(orbView)
        let pips = PassthroughHostingView(rootView: ArcPipsView(model: model))
        pips.sizingOptions = []
        container.addSubview(pips)
        self.pips = pips
        contentView = container
        layoutPips()
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        startClickThrough()
    }

    /// The centre guides shown while the orb is dragged.
    var guides: SnapGuidePanel? {
        get { orbView.guides }
        set { orbView.guides = newValue }
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
        // Keep it where it was, hanging off an edge if it was; only pull it back within the drag limits.
        if let screen = Self.screen(nearest: centre) {
            target.origin = BubblePlacement.clampedOrigin(target.origin, side: side, screen: screen.frame, visible: screen.visibleFrame)
        }
        expectedOrigin = target.origin
        setFrame(target, display: true)
        layoutPips()
    }

    /// The pip arc is laid out in the full panel; its view scales with the orb size.
    private func layoutPips() {
        pips.frame = NSRect(x: 0, y: 0, width: frame.width, height: frame.width)
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// The screen holding `point`, else the one nearest to it (for an orb dragged partly off every screen).
    static func screen(nearest point: CGPoint) -> NSScreen? {
        screen(containing: point) ?? NSScreen.screens.min { a, b in
            func gap(_ f: CGRect) -> CGFloat {
                hypot(max(f.minX - point.x, 0, point.x - f.maxX), max(f.minY - point.y, 0, point.y - f.maxY))
            }
            return gap(a.frame) < gap(b.frame)
        }
    }

    // MARK: Flying between styles

    /// Mid-flight (switching to or from the island): moves aren't the user's and aren't saved.
    private(set) var isFlying = false
    private var flight: Timer?

    /// Fades the pip arc (hidden while the orb flies, as the island draws its own).
    func setPipsVisible(_ visible: Bool, duration: Double = 0.18) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            pips.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Flies the panel (so the live orb draws all the way) from `start` to `end` along a gentle arc, resizing as it
    /// goes; `done` runs on landing, not if the flight is cancelled.
    func fly(from start: CGRect, to end: CGRect, duration: Double = 0.55, done: @escaping () -> Void) {
        cancelFlight()
        isFlying = true
        setFrame(start, display: true)
        let a = CGPoint(x: start.midX, y: start.midY), b = CGPoint(x: end.midX, y: end.midY)
        let control = StyleMorph.arcControl(from: a, to: b)
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, (CACurrentMediaTime() - began) / duration)
            let e = StyleMorph.ease(t)
            let centre = StyleMorph.point(on: a, control, b, at: e)
            let side = start.width + (end.width - start.width) * e
            self.setFrame(CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side), display: true)
            guard t >= 1 else { return }
            self.cancelFlight()
            self.setFrame(end, display: true)
            done()
        }
        RunLoop.main.add(timer, forMode: .common)
        flight = timer
    }

    /// Stops a flight where it is (the caller puts the panel where it belongs).
    func cancelFlight() {
        flight?.invalidate()
        flight = nil
        isFlying = false
    }

    /// Puts the panel back without it counting as a move (after a flight, while hidden).
    func restore(_ frame: CGRect) {
        isFlying = true
        setFrame(frame, display: false)
        isFlying = false
        layoutPips()
    }

    @objc private func didMove() {
        if isFlying { return }
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
