import AppKit
import ClaudeBubbleCore
import Combine
import SwiftUI

/// What the island draws beyond the shared sessions model.
final class IslandModel: ObservableObject {
    @Published var mode: IslandMode = .rest
    @Published var dock: IslandDock = .top
    @Published var rest: IslandRest = .live
    @Published var glow: IslandGlow = .waves
    /// The look the orb is showing (drives the glow colour and pace); `.idle` with `done` shows the success green.
    @Published var state: BubbleState = .idle
    /// Recent tool-complete ticks (seconds, CACurrentMediaTime) that brighten the wave.
    @Published var ticks: [Double] = []
}

/// The docked pill (design: Top Island). A fixed, mostly click-through window; the pill inside animates.
final class IslandPanel: NSPanel {
    let model = IslandModel()
    private let orbView: OrbView

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent, NSView) -> Void)?

    init(animator: OrbAnimator, sessions: SessionsModel) {
        // As in the design, the 28pt slot is the orb's whole canvas (halo included); the orb itself is ~17pt.
        let side = IslandLayout.orbSize
        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: side, height: side), animator: animator)
        orbView.allowsDrag = false
        orbView.crisp = true
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
        let host = IslandHostingView(rootView: IslandView(model: model, sessions: sessions, orb: orbView,
                                                         onClick: { [weak self] in self?.onClick?() }))
        host.onRightClick = { [weak self] event, view in self?.onRightClick?(event, view) }
        orbView.onClick = { [weak self] in self?.onClick?() }
        orbView.onRightClick = { [weak self] event, view in self?.onRightClick?(event, view) }
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setRendering(_ on: Bool) { orbView.isPaused = !on }

    /// Only the pill takes the mouse.
    func updateMouseCapture(pill: CGRect) {
        let over = isVisible && pill.contains(NSEvent.mouseLocation)
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
    }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: ((NSEvent, NSView) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event, self) }
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
    let onClick: () -> Void

    private var live: [Session] { SessionStore.sorted(sessions.sessions) }
    private var sideRest: Bool { model.dock.isSide && model.mode == .rest }
    private var size: CGSize {
        IslandLayout.size(mode: model.mode, dock: model.dock, rest: model.rest, pips: live.count, rows: live.count)
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

    private var shape: UnevenRoundedRectangle {
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
        if sideRest { return CGPoint(x: size.width / 2, y: 8 + half) }
        return CGPoint(x: 10 + half, y: model.dock == .bottom ? size.height - 8 - half : 8 + half)
    }

    private var pill: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if model.glow == .waves {
                IslandGlowView(model: model, palette: sessions.palette, orbCentre: orbCentre, waves: model.mode != .hover,
                               edge: !sideRest)
            }
            content
            OrbHost(view: orb)
                .frame(width: IslandLayout.orbSize, height: IslandLayout.orbSize)
                .position(orbCentre)
        }
        .clipShape(shape)
        .overlay(model.glow == .waves ? IslandRim(shape: shape, color: glowColor, state: model.state) : nil)
        .shadow(color: .black.opacity(0.55), radius: 15, y: 10)
        .contentShape(shape)
        .onTapGesture(perform: onClick)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            if model.mode == .rest {
                HStack(spacing: 4) { ForEach(Array(live.prefix(IslandLayout.maxPips)), id: \.id) { pip($0) } }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .frame(height: IslandLayout.orbSize + 16)
    }

    @ViewBuilder private var detail: some View {
        switch model.mode {
        case let .needs(id), let .error(id):
            if let s = live.first(where: { $0.id == id }) {
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
            VStack(spacing: 2) {
                ForEach(live, id: \.id) { s in
                    SessionRow(session: s, now: Date(), palette: sessions.palette).onTapGesture(perform: onClick)
                }
                if sessions.today != nil || sessions.usage != nil {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 4)
                    TodayFooter(summary: sessions.today, usage: sessions.usage, palette: sessions.palette)
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
        case .rest:
            guard !live.isEmpty else { return "No sessions" }
            let focus = SessionStore.motionFocus(live) ?? live.first!
            return focus.state == .working && !focus.detail.isEmpty ? focus.detail : focus.state == .idle ? "Idle" : focus.detail
        }
    }

    private var barColor: Color {
        switch model.mode {
        case .needs: BubbleState.needs.color(in: sessions.palette)
        case .error: BubbleState.error.color(in: sessions.palette)
        case .done: IslandGlowView.doneColor
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

    static let doneColor = Color(red: 0.47, green: 0.9, blue: 0.67)

    static func color(state: BubbleState, done: Bool, palette: OrbPalette) -> Color {
        if done { return doneColor }
        return state.color(in: palette)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let media = CACurrentMediaTime()
            let fast = model.state == .needs || model.state == .error
            let breath = 0.5 + 0.5 * sin(now * (fast ? 4.2 : 1.7))
            let kick = min(1, model.ticks.reduce(0) { $0 + exp(-(media - $1) * 7) })
            let pace = (model.state == .idle && model.mode != .done ? 0.45 : fast ? 1.35 : 1) * (1 + 0.5 * kick)
            let color = Self.color(state: model.state, done: model.mode == .done, palette: palette)
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
                RadialGradient(stops: [.init(color: color.opacity(0.7), location: 0),
                                       .init(color: color.opacity(0.38), location: 0.09 * r),
                                       .init(color: color.opacity(0.12), location: 0.22 * r),
                                       .init(color: color.opacity(0.03), location: 0.36 * r),
                                       .init(color: .clear, location: 0.5 * r)],
                               center: .center, startRadius: 0, endRadius: reach)
                    .frame(width: 440, height: 440)
                    .mask(Rectangle().fill(ImagePaint(image: Self.dot, scale: 1)))
                    .position(orbCentre)
                    .opacity(min(1, (0.45 + 0.25 * breath) * pace))
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
                            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: min(1, 34 / h)),
                                                   .init(color: .clear, location: min(1, 96 / h))],
                                           startPoint: model.dock == .bottom ? .bottom : .top,
                                           endPoint: model.dock == .bottom ? .top : .bottom)
                        })
                }
                if waves {
                    Canvas { ctx, size in
                        drawWaves(ctx, size: size, time: now, kick: kick, breath: breath, color: color)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Ported from the design's canvas: a 4pt dot grid, each dot pushed outward and lit by two travelling waves.
    private func drawWaves(_ ctx: GraphicsContext, size: CGSize, time: Double, kick: Double, breath: Double, color: Color) {
        let idle = model.state == .idle && model.mode != .done
        let fast = model.state == .needs || model.state == .error
        let amp = (idle ? 0.45 : 1) * (1 + 0.6 * kick)
        let tt = time * (idle ? 0.5 : fast ? 1.6 : 1.1)
        let oz = Double(IslandLayout.orbSize)
        let ox = Double(orbCentre.x), oy = Double(orbCentre.y)
        let r0 = max(Double(size.width) * 0.9, 160)
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
                let a = min(1, fall * fall * (0.1 + crest * amp) * (0.7 + 0.3 * breath))
                if a < 0.02 { continue }
                let rad = 0.55 + crest * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: px - rad, y: py - rad, width: rad * 2, height: rad * 2)),
                         with: .color(color.opacity(a)))
            }
            gx += 4
        }
    }
}

/// The pill's 1pt inner rim in the state colour, breathing with the glow (design: inset box-shadow).
private struct IslandRim: View {
    let shape: UnevenRoundedRectangle
    let color: Color
    let state: BubbleState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let fast = state == .needs || state == .error
            let breath = 0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * (fast ? 4.2 : 1.7))
            shape.strokeBorder(color.opacity(0.06 + 0.04 * breath), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
