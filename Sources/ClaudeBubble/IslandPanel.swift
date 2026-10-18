import AppKit
import ClaudeBubbleCore
import HookCore
import Combine
import SwiftUI

/// What the island draws beyond the shared sessions model.
final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .rest
    @Published var dock: IslandDock = .top
    @Published var rest: IslandRest = .live
    @Published var glow: IslandGlow = .waves
    /// The Width setting (a multiple of the design's widths).
    @Published var width: CGFloat = 1
    /// The look the orb is showing (drives the glow colour and pace); `.idle` with `done` shows the success green.
    @Published var state: BubbleState = .idle
    /// Recent tool-complete ticks (seconds, CACurrentMediaTime) that brighten the wave. Not published: the glow's
    /// timeline reads them every frame anyway, and publishing re-rendered the whole island for each tool call.
    var ticks: [Double] = []
    /// The glow colour's source, and the one it's fanning away from (with when the fan began).
    @Published var colorKey = IslandColorKey(state: .idle, done: false)
    @Published var fanFrom: IslandColorKey?
    @Published var fanStart: Double = 0
    /// Off while the island is hidden: the Metal glow stops drawing.
    private(set) var rendering = true
    /// The Metal glow layers, paused and resumed with the island. Set directly: SwiftUI doesn't update the views of
    /// a hidden window, so a published flag never reached them (the glow kept drawing behind the orb).
    let glowLayers = NSHashTable<GlowMetalView>.weakObjects()

    func setRendering(_ on: Bool) {
        rendering = on
        for view in glowLayers.allObjects where view.isPaused == on { view.isPaused = !on }
    }

    static let fanDuration = 1.4

    /// The colour now, the one it's fanning from, and how far the fan has got (1 = done).
    func colors(palette: OrbPalette, at now: Double) -> (to: SIMD3<Double>, from: SIMD3<Double>, progress: Double) {
        let to = colorKey.rgb(palette)
        guard let from = fanFrom else { return (to, to, 1) }
        let p = min(1, max(0, (now - fanStart) / Self.fanDuration))
        return (to, from.rgb(palette), p)
    }
}

/// What the island's glow colour comes from.
struct IslandColorKey: Equatable {
    let state: BubbleState
    let done: Bool

    func rgb(_ palette: OrbPalette) -> SIMD3<Double> {
        // The all-done colour's deeper tone, which reads better as a glow than its pale main colour.
        if done { let c = palette.done.c2; return [Double(c.x), Double(c.y), Double(c.z)] }
        let c = palette[state].swatch
        return [Double(c.x), Double(c.y), Double(c.z)]
    }
}

private extension SIMD3 where Scalar == Double {
    var color: Color { Color(red: x, green: y, blue: z) }
    func mixed(to other: SIMD3<Double>, _ t: Double) -> SIMD3<Double> { self + (other - self) * t }
}

/// The docked pill (design: Top Island). A fixed, mostly click-through window; the pill inside animates.
final class IslandPanel: NSPanel {
    let model = IslandModel()
    private let orbView: OrbView

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?
    /// Dragging the island around the screen's edges: the pointer (screen space), then the release.
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    init(animator: OrbAnimator, sessions: SessionsModel) {
        // As in the design, the 28pt slot is the orb's whole canvas (halo included); the orb itself is ~17pt.
        let side = IslandLayout.orbSize
        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: side, height: side), animator: animator)
        orbView.allowsDrag = false
        orbView.passesMouseThrough = true
        orbView.crisp = true
        orbView.preferredFramesPerSecond = 30   // a ~20pt orb looks the same at half the frames
        super.init(contentRect: CGRect(origin: .zero, size: IslandLayout.windowSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        let host = IslandHostingView(rootView: IslandView(model: model, sessions: sessions, orb: orbView))
        // The window is sized by hand. Left to its defaults, the hosting view re-measures its whole tree for the
        // window's min/max size on every animation frame (the glow), which was most of the app's CPU.
        host.sizingOptions = []
        host.onRightClick = { [weak self] event, view in self?.onRightClick?(event, view) }
        host.onClick = { [weak self] in self?.onClick?() }
        host.onDragMoved = { [weak self] point in
            self?.dragging = true
            self?.onDragMoved?(point)
        }
        host.onDragEnded = { [weak self] in
            self?.dragging = false
            self?.onDragEnded?()
            self?.updateMouseCapture()
        }
        contentView = host
        startMouseCapture()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows below the menu bar strip of every display, even where it's hidden (full screen); the
    /// island places itself (under a showing menu bar, else at the very top), so leave its frame alone.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Moving to another display: fade out, jump, then fade in sliding from the docked edge (not a jump cut).
    private(set) var isSwapping = false
    func swap(to frame: CGRect, dock: IslandDock, opacity: Double) {
        guard !isSwapping else { return }
        isSwapping = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            let slide: CGFloat = 14
            var start = frame
            switch dock {
            case .top: start.origin.y += slide
            case .bottom: start.origin.y -= slide
            case .left: start.origin.x -= slide
            case .right: start.origin.x += slide
            }
            self.setFrame(start, display: true)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.32
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.05)
                self.animator().alphaValue = opacity
                self.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in self?.isSwapping = false })
        })
    }

    func setRendering(_ on: Bool) {
        orbView.isPaused = !on
        model.setRendering(on)
    }

    /// Where the pill is on screen (kept current by the app); only it takes the mouse.
    var pill: CGRect = .zero { didSet { updateMouseCapture() } }
    private var mouseMonitors: [Any] = []

    /// Follow the pointer between the 20Hz ticks too, so a quick click lands where it looks like it will.
    private func startMouseCapture() {
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

    /// Mid-drag the window moves under the pointer; keep the mouse until the release.
    private var dragging = false

    func updateMouseCapture() {
        let over = isVisible && (dragging || pill.contains(NSEvent.mouseLocation))
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
    }
}

/// Takes the island's mouse itself: a press that doesn't move is a click (focus the terminal), one that moves 3pt
/// becomes a drag around the screen's edges.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: ((NSEvent, NSView) -> Void)?
    var onClick: (() -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var downAt: CGPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event, self) }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a right-click on macOS, as on the orb.
        if event.modifierFlags.contains(.control) { onRightClick?(event, self); return }
        downAt = NSEvent.mouseLocation
        downEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - start.x, p.y - start.y) > 3 { dragging = true }
        if dragging { onDragMoved?(p) }
    }

    private var downEvent: NSEvent?

    override func mouseUp(with event: NSEvent) {
        if downAt != nil {
            if dragging {
                onDragEnded?()
            } else {
                // A plain click: let the content see it first (a link chip opens its link); otherwise focus the terminal.
                ChipClick.handled = false
                if let down = downEvent { super.mouseDown(with: down) }
                super.mouseUp(with: event)
                if !ChipClick.handled { onClick?() }
            }
        }
        downAt = nil
        downEvent = nil
        dragging = false
    }
}

/// Hosts the island's own Metal orb view (one instance, always in the same place in the hierarchy).
private struct OrbHost: NSViewRepresentable {
    let view: OrbView
    func makeNSView(context: Context) -> OrbView { view }
    func updateNSView(_ nsView: OrbView, context: Context) {}
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sessions: SessionsModel
    let orb: OrbView
    @Environment(\.isSnapshot) private var snapshot

    private var live: [Session] { sessions.sorted }
    private var sideRest: Bool { model.dock.isSide && model.mode == .rest }
    private var tucked: Bool { model.mode == .tucked }
    private var hasFooter: Bool { sessions.today != nil || sessions.usage != nil }
    private var size: CGSize {
        IslandLayout.size(mode: model.mode, dock: model.dock, rest: model.rest, pips: live.count, rows: live.count,
                          footer: hasFooter, linked: IslandLayout.linkedRows(live),
                          approval: sessions.islandApprovalHeight(model.mode), width: model.width)
    }

    /// The prompt the needs-you card offers Allow and Deny for.
    private var approval: ApprovalRequest? {
        guard case let .needs(id) = model.mode, let s = sessions.byID[id] else { return nil }
        return sessions.approval(for: s)
    }
    private let spring = Animation.spring(response: 0.5, dampingFraction: 0.72)

    var body: some View {
        pill
            .frame(width: size.width, height: size.height)
            .animation(spring, value: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: windowAlignment)
    }

    private var windowAlignment: Alignment {
        switch model.dock {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var dockedEdge: Edge.Set {
        switch model.dock {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private var quiet: Bool { model.mode == .quiet }

    private var shape: UnevenRoundedRectangle {
        if quiet {
            let r = IslandLayout.quietDot / 2
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, bottomTrailingRadius: r, topTrailingRadius: r)
        }
        let r = IslandLayout.cornerRadius
        switch model.dock {
        case .top: return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
        case .bottom: return UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r)
        case .left: return UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r)
        case .right: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r)
        }
    }

    /// The orb's centre inside the pill.
    private var orbCentre: CGPoint {
        let half = IslandLayout.orbSize / 2
        if sideRest || (tucked && model.dock.isSide) { return CGPoint(x: size.width / 2, y: 8 + half) }
        let inset = IslandLayout.dockedInset
        return CGPoint(x: 10 + half, y: model.dock == .bottom ? size.height - inset - half : inset + half)
    }

    private var pill: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if quiet {
                QuietDot(color: glowColor, urgent: live.contains { $0.state == .needs || $0.state == .error })
                    .transition(.opacity)
            } else {
                if model.glow == .waves {
                    if snapshot {
                        IslandGlowView(model: model, palette: sessions.palette, orbCentre: orbCentre, waves: true,
                                       edge: !sideRest)
                    } else {
                        GlowHost(kind: .glow, model: model, palette: sessions.palette, orbCentre: orbCentre, edge: !sideRest)
                    }
                    if hasDetail { scrim }
                }
                content
                    .opacity(tucked ? 0 : 1)
            }
            // Always in the hierarchy (one Metal view), just hidden while quiet.
            Group {
                // Rendered offscreen (README images), where the Metal view can't draw: a still of the orb.
                if snapshot, let still = OrbSnapshot.render(state: model.state, size: Int(IslandLayout.orbSize * 4), palette: sessions.palette) {
                    Image(decorative: still, scale: 4)
                } else {
                    OrbHost(view: orb)
                }
            }
                .frame(width: IslandLayout.orbSize, height: IslandLayout.orbSize)
                .position(orbCentre)
                .opacity(quiet ? 0 : 1)
        }
        .clipShape(shape)
        .overlay(model.glow == .waves ? rim : nil)
        // A faint outline so the island stands out against dark windows; none on the docked edge, which meets the screen's.
        .overlay(shape.strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            .mask(Rectangle().padding(dockedEdge, 1))
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.55), radius: 15, y: 10)
        .contentShape(shape)
    }

    @ViewBuilder private var rim: some View {
        if snapshot { IslandRim(shape: shape, model: model, palette: sessions.palette) }
        else { GlowHost(kind: .rim, model: model, palette: sessions.palette).allowsHitTesting(false) }
    }

    /// Showing text beyond the bar: the session list, or a needs-you or error message.
    private var hasDetail: Bool {
        switch model.mode {
        case .hover, .needs, .error: true
        default: false
        }
    }

    /// Darkens the glow behind the text so it stays readable, fading in from the bar so the glow still blooms there.
    private var scrim: some View {
        let bar = IslandLayout.barHeight, fade: CGFloat = 26
        let h = max(size.height, 1)
        let start = min(1, (bar - 8) / h), full = min(1, (bar + fade) / h)
        let stops: [Gradient.Stop] = [.init(color: .clear, location: 0), .init(color: .clear, location: start),
                                      .init(color: .black.opacity(0.7), location: full), .init(color: .black.opacity(0.7), location: 1)]
        return LinearGradient(stops: stops, startPoint: model.dock == .bottom ? .bottom : .top,
                              endPoint: model.dock == .bottom ? .top : .bottom)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var glowColor: Color { IslandGlowView.color(state: model.state, done: model.mode == .done, palette: sessions.palette) }

    @ViewBuilder private var content: some View {
        if sideRest {
            VStack(spacing: 4) {
                ForEach(Array(live.prefix(IslandLayout.maxPips)), id: \.id) { pip($0) }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8 + IslandLayout.orbSize + 10)
            .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if model.dock == .bottom { detail; bar } else { bar; detail }
            }
            .frame(width: size.width, height: size.height, alignment: model.dock == .bottom ? .bottom : .top)
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: IslandLayout.orbSize, height: IslandLayout.orbSize)   // the orb sits here
            if !(model.mode == .rest && model.rest == .compact) {
                Text(barText)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(barColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // A soft dark halo behind every letter, so the bar's text stays legible over the brightest glow.
                    // Only here: below the bar the scrim darkens the glow, and a halo would smudge buttons and chips.
                    .shadow(color: .black.opacity(model.glow == .waves ? 0.9 : 0), radius: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            if model.mode == .rest {
                HStack(spacing: 4) { ForEach(Array(live.prefix(IslandLayout.maxPips)), id: \.id) { pip($0) } }
            }
        }
        .frame(height: IslandLayout.orbSize)
        .padding(.leading, 10)
        .padding(.trailing, 20)
        // Tight against the docked edge, roomier on the open side.
        .padding(model.dock == .bottom ? .bottom : .top, IslandLayout.dockedInset)
        .padding(model.dock == .bottom ? .top : .bottom, IslandLayout.openInset)
    }

    @ViewBuilder private var detail: some View {
        switch model.mode {
        case let .needs(id), let .error(id):
            if let s = live.first(where: { $0.id == id }), let approval, model.mode == .needs(id) {
                // A permission prompt: what Claude wants, then the request in full with Deny and Allow.
                VStack(alignment: .leading, spacing: 8) {
                    Text(approval.headline)
                        .font(.system(size: 12.5))
                        .foregroundStyle(s.state.color(in: sessions.palette))
                        .lineLimit(1).truncationMode(.tail)
                        .frame(height: 18)
                    ApprovalCard(request: approval, accent: BubbleState.needs.color(in: sessions.palette),
                                 width: sessions.needsCardWidth,
                                 onAnswer: { sessions.answer?(approval, $0) }) { sessions.decide?(approval, $0) }
                }
                .padding(.leading, 22 + IslandLayout.orbSize)
                .padding(.trailing, 20)
                .transition(.opacity)
            } else if let s = live.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.detail.isEmpty ? (model.mode == .needs(id) ? "Needs you" : "Error") : s.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(s.state.color(in: sessions.palette))
                        .lineLimit(1).truncationMode(.tail)
                    Text(s.project)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                }
                .padding(.leading, 22 + IslandLayout.orbSize)
                .padding(.trailing, 20)
                .transition(.opacity)
            }
        case .hover:
            // Ticks once a second so the rows' elapsed times stay current.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 2) {
                    ForEach(Array(live.prefix(IslandLayout.maxRows)), id: \.id) { s in
                        let asking = sessions.approval(for: s)
                        SessionRow(session: s, now: context.date, palette: sessions.palette,
                                   pinned: sessions.pinned.contains(s.id), onPin: { sessions.togglePin(s.id) },
                                   approval: asking, expanded: asking != nil && asking?.id == sessions.expandedApproval?.id,
                                   width: sessions.islandRowWidth,
                                   onDecide: asking.map { request in { sessions.decide?(request, $0) } },
                                   onAnswer: asking.map { request in { sessions.answer?(request, $0) } })
                    }
                    if live.count > IslandLayout.maxRows {
                        Text("+\(live.count - IslandLayout.maxRows) more")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .frame(height: IslandLayout.moreHeight - 2)
                    }
                    if hasFooter {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 4)
                        TodayFooter(summary: sessions.today, usage: sessions.usage, palette: sessions.palette)
                    }
                }
            }
            .padding(.horizontal, 8)
            .transition(.opacity)
        default:
            EmptyView()
        }
    }

    private func pip(_ s: Session) -> some View {
        let c = s.pipColor(in: sessions.palette)
        let urgent = s.state == .needs || s.state == .error
        return Circle().fill(c).frame(width: IslandLayout.pipSize, height: IslandLayout.pipSize)
            .shadow(color: urgent ? c : .clear, radius: 3)
    }

    private var barText: String {
        switch model.mode {
        case let .needs(id): return "\(name(id)) needs you"
        case let .error(id): return "\(name(id)) hit an error"
        case .done: return "All sessions complete"
        case .hover: return "Sessions"
        case .quiet, .tucked: return ""
        case .rest:
            guard !live.isEmpty else { return "No sessions" }
            let focus = SessionStore.motionFocus(live) ?? live.first!
            if focus.state == .idle { return focus.restingLabel }
            return focus.detail.isEmpty ? focus.state.settingsLabel : focus.detail
        }
    }

    private var barColor: Color {
        switch model.mode {
        case .needs: BubbleState.needs.color(in: sessions.palette)
        case .error: BubbleState.error.color(in: sessions.palette)
        case .done: IslandGlowView.color(state: .idle, done: true, palette: sessions.palette)
        default: .white
        }
    }

    private func name(_ id: String) -> String { live.first { $0.id == id }?.displayName ?? "A session" }
}

/// The "waves + inner" glow: a rolling dot-wave radiating from the orb, and a soft breathing glow behind it.
struct IslandGlowView: View {
    @ObservedObject var model: IslandModel
    let palette: OrbPalette
    let orbCentre: CGPoint
    /// The dot-wave (off while the session panel is open, to keep it readable and cheap).
    let waves: Bool
    /// The edge strip (off for the narrow side capsule).
    let edge: Bool

    /// One cell of the pixel glow's dot grid: a 1.05pt dot (soft to 1.6pt) every 4pt, tiled.
    static let dot: Image = {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { _ in
            let g = NSGradient(colors: [.white, .white, .clear], atLocations: [0, 1.05 / 1.6, 1], colorSpace: .deviceRGB)
            g?.draw(fromCenter: NSPoint(x: 2, y: 2), radius: 0, toCenter: NSPoint(x: 2, y: 2), radius: 1.6, options: [])
            return true
        }
        return Image(nsImage: image)
    }()


    /// How fast the dot-wave rolls (the design's speeds, slowed to 60%: calmer on a desktop you look at all day).
    static func waveSpeed(idle: Bool, fast: Bool) -> Double {
        (idle ? 0.5 : fast ? 1.6 : 1.1) * 0.6
    }

    static func color(state: BubbleState, done: Bool, palette: OrbPalette) -> Color {
        if done { let c = palette.done.c2; return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }
        return state.color(in: palette)
    }

    var body: some View {
        // Full rate while something needs you or failed; calmer (and cheaper) otherwise.
        TimelineView(.animation(minimumInterval: model.state == .needs || model.state == .error ? 1.0 / 30 : 1.0 / 20)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let media = CACurrentMediaTime()
            let fast = model.state == .needs || model.state == .error
            let breath = 0.5 + 0.5 * sin(now * (fast ? 4.2 : 1.7))
            let kick = min(1, model.ticks.reduce(0) { $0 + exp(-(media - $1) * 7) })
            let pace = (model.state == .idle && model.mode != .done ? 0.45 : fast ? 1.35 : 1) * (1 + 0.5 * kick)
            // Colour changes fan out from the orb: the glows blend over the fan, the dot-wave switches along its front.
            let fan = model.colors(palette: palette, at: media)
            let eased = 1 - pow(1 - fan.progress, 3)
            let color = fan.from.mixed(to: fan.to, eased).color
            ZStack(alignment: .topLeading) {
                // Behind the orb (design: innerS + inner): a soft glow, then a stronger one seen through a dot grid
                // so it reads as lit pixels.
                let r = 1 + 0.12 * breath + 0.1 * kick
                let reach: CGFloat = 311   // the design's 440pt box, farthest-corner radius
                RadialGradient(stops: [.init(color: color.opacity(0.35), location: 0),
                                       .init(color: color.opacity(0.1), location: 0.14 * r),
                                       .init(color: .clear, location: 0.36 * r)],
                               center: .center, startRadius: 0, endRadius: reach)
                    .frame(width: 440, height: 440)
                    .position(orbCentre)
                    .opacity(min(1, (0.5 + 0.3 * breath) * pace))
                RadialGradient(stops: [.init(color: color.opacity(0.9), location: 0),
                                       .init(color: color.opacity(0.55), location: 0.09 * r),
                                       .init(color: color.opacity(0.2), location: 0.22 * r),
                                       .init(color: color.opacity(0.05), location: 0.36 * r),
                                       .init(color: .clear, location: 0.5 * r)],
                               center: .center, startRadius: 0, endRadius: reach)
                    .frame(width: 440, height: 440)
                    .mask(Rectangle().fill(ImagePaint(image: Self.dot, scale: 1)))
                    .position(orbCentre)
                    .opacity(min(1, (0.6 + 0.3 * breath) * pace))
                // Edge glow (design: edge): a bright strip down the orb's edge of the pill, fading away from the dock.
                if edge {
                    LinearGradient(stops: [.init(color: color.opacity(0.55 + 0.25 * breath), location: 0),
                                           .init(color: color.opacity(0.5 + 0.2 * breath), location: 1.5 / 26),
                                           .init(color: color.opacity(0.22 + 0.12 * breath), location: 3 / 26),
                                           .init(color: color.opacity(0.06), location: 12 / 26),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 26)
                        .frame(maxHeight: .infinity)
                        .mask(GeometryReader { geo in
                            let h = max(geo.size.height, 1)
                            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: min(1, 48 / h)),
                                                   .init(color: .clear, location: min(1, 140 / h))],
                                           startPoint: model.dock == .bottom ? .bottom : .top,
                                           endPoint: model.dock == .bottom ? .top : .bottom)
                        })
                }
                if waves {
                    Canvas { ctx, size in
                        PerfMeter.shared.count(.glowFrame)
                        drawWaves(ctx, size: size, time: now, kick: kick, breath: breath, to: fan.to.color,
                                  from: fan.from.color, fan: fan.progress)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Ported from the design's canvas: a 4pt dot grid, each dot pushed outward and lit by two travelling waves.
    private func drawWaves(_ ctx: GraphicsContext, size: CGSize, time: Double, kick: Double, breath: Double,
                           to color: Color, from oldColor: Color, fan: Double) {
        let idle = model.state == .idle && model.mode != .done
        let fast = model.state == .needs || model.state == .error
        // Brighter than the design's numbers: on a real desktop the wave read too faint next to the prototype.
        let amp = (idle ? 0.45 : 1) * (1 + 0.6 * kick) * 1.8
        let tt = time * Self.waveSpeed(idle: idle, fast: fast)
        let oz = Double(IslandLayout.orbSize)
        let ox = Double(orbCentre.x), oy = Double(orbCentre.y)
        let r0 = max(Double(size.width) * 0.9, 160)
        // Dots are grouped by brightness into a few paths, so a frame is 8 fills (16 mid-fan), not thousands.
        let buckets = 8
        var paths = Array(repeating: Path(), count: buckets)
        var oldPaths = Array(repeating: Path(), count: buckets)
        // The fan's front: a radius growing out from the orb past the far end of the pill.
        let front = fan < 1 ? fan * (r0 * 1.15 + 20) : .infinity
        var gx = 2.0
        while gx < Double(size.width) {
            var gy = 2.0
            while gy < Double(size.height) {
                defer { gy += 4 }
                let dx = gx - ox, dy = gy - oy
                let d0 = (dx * dx + dy * dy).squareRoot()
                if d0 < oz / 2 + 1 { continue }
                let an = atan2(dy, dx)
                let warp = sin(an * 3 + tt * 0.45) * 0.55 + sin(gx * 0.019 - gy * 0.043 + tt * 0.35) * 0.7
                let w1 = sin(d0 * 0.085 - tt * 2.3 + warp), w2 = sin(d0 * 0.045 - tt * 1.2 + an * 2 + warp * 0.5)
                let patch = 0.5 + 0.5 * (0.5 + 0.5 * sin(an * 2.3 + tt * 0.3) * sin(d0 * 0.03 - tt * 0.2))
                let born = min(1, (d0 - oz / 2 - 1) / 16)
                let crest = (pow(0.5 + 0.5 * w1, 2.6) * 0.9 + pow(0.5 + 0.5 * w2, 3) * 0.3) * patch * born
                let push = crest * 1.8 + sin(d0 * 0.06 - tt * 1.6) * 0.5
                let px = gx + cos(an) * push, py = gy + sin(an) * push, dist = d0 + push
                let fall = max(0, 1 - dist / r0)
                if fall <= 0 { continue }
                var a = min(1, fall * fall * (0.16 + crest * amp) * (0.7 + 0.3 * breath))
                // Dots just inside the fan's front light up a little.
                let edge = front.isFinite ? exp(-pow((d0 - front + 8) / 10, 2)) * (1 - fan) : 0
                a = min(1, a + edge * 0.5)
                if a < 0.02 { continue }
                let rad = 0.6 + crest * 0.6 + edge * 0.5
                let dot = CGRect(x: px - rad, y: py - rad, width: rad * 2, height: rad * 2)
                let bucket = min(buckets - 1, Int(a * Double(buckets)))
                if d0 < front { paths[bucket].addEllipse(in: dot) } else { oldPaths[bucket].addEllipse(in: dot) }
            }
            gx += 4
        }
        for i in 0..<buckets {
            let alpha = (Double(i) + 0.75) / Double(buckets)
            if !paths[i].isEmpty { ctx.fill(paths[i], with: .color(color.opacity(alpha))) }
            if !oldPaths[i].isEmpty { ctx.fill(oldPaths[i], with: .color(oldColor.opacity(alpha))) }
        }
    }
}

/// The pill's 1pt inner rim in the state colour, breathing with the glow (design: inset box-shadow).
private struct IslandRim: View {
    let shape: UnevenRoundedRectangle
    @ObservedObject var model: IslandModel
    let palette: OrbPalette

    var body: some View {
        // On the glow's schedule, so the two redraw together rather than in between each other's frames.
        TimelineView(.animation(minimumInterval: model.state == .needs || model.state == .error ? 1.0 / 30 : 1.0 / 20)) { context in
            let fast = model.state == .needs || model.state == .error
            let breath = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * (fast ? 4.2 : 1.7))
            let fan = model.colors(palette: palette, at: CACurrentMediaTime())
            let color = fan.from.mixed(to: fan.to, 1 - pow(1 - fan.progress, 3)).color
            shape.strokeBorder(color.opacity(0.06 + 0.04 * breath), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Quiet mode's dot: the state colour, breathing when something needs you or failed.
private struct QuietDot: View {
    let color: Color
    let urgent: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !urgent)) { context in
            let b = urgent ? 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4.2) : 0.5
            Circle()
                .fill(color)
                .padding(4)
                .scaleEffect(0.85 + 0.2 * b)
                .shadow(color: color.opacity(0.4 + 0.5 * b), radius: 2 + 3 * b)
                .frame(width: IslandLayout.quietDot, height: IslandLayout.quietDot)
        }
        .allowsHitTesting(false)
    }
}
