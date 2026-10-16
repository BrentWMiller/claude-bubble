import AppKit
import ClaudeBubbleCore
import SwiftUI

extension BubbleState {
    /// The color the orb reads as in this state, for pips, wells and fallbacks.
    func color(in palette: OrbPalette) -> Color {
        let c = palette[self].swatch
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var settingsLabel: String {
        switch self {
        case .idle: "Completed"
        case .working: "Working"
        case .needs: "Needs you"
        case .error: "Error"
        }
    }
}

/// Session pips on an arc under the orb, choreographed by `PipChoreographer` (spawn, hop, shake, flare, merge).
extension StatusTone {
    /// Status colours follow the orb's palette: needs/review, error, working, and finished take its swatches;
    /// sessions that went quiet without finishing stay grey.
    func color(in palette: OrbPalette) -> Color {
        let state: BubbleState
        switch self {
        case .attention: state = .needs
        case .error: state = .error
        case .working: state = .working
        case .completed: state = .idle
        case .idle: return Color.white.opacity(0.45)
        }
        return state.color(in: palette)
    }
}

extension Session {
    /// The pip colour, shared by the arc and the hover list.
    func pipColor(in palette: OrbPalette) -> Color { tone.color(in: palette) }
}

struct ArcPipsView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let centre = CGPoint(x: side / 2, y: side / 2)
            let radius = side * 0.3 * PipArc.radiusScale
            let frame = model.pips
            ZStack {
                ForEach(frame.pips, id: \.id) { pip in
                    PipDot(pip: pip, frame: frame, centre: centre, radius: radius,
                           around: model.pipAround, color: pipColor(pip),
                           hovered: model.hoveredPip == pip.id)
                }
                if frame.overflow > 0 {
                    Text("+\(frame.overflow)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .position(PipArc.position(slot: frame.slots - 1, slots: frame.slots, centre: centre, radius: radius, around: model.pipAround))
                        .opacity(frame.merged ? 0 : 1)
                        .animation(.easeOut(duration: 0.3), value: frame.merged)
                }
            }
        }
        .opacity(model.present && model.pips.visible && !model.quiet ? 1 : 0)
        .animation(model.present ? .spring(response: 0.45, dampingFraction: 0.5) : .easeIn(duration: 0.15), value: model.present)
    }

    private func pipColor(_ pip: PipFrame) -> Color {
        guard let session = model.sessions.first(where: { $0.id == pip.id }) else {
            return (pip.review ? BubbleState.needs : pip.state).color(in: model.palette)
        }
        return session.pipColor(in: model.palette)
    }
}

private struct PipDot: View {
    let pip: PipFrame
    let frame: PipsFrame
    let centre: CGPoint
    let radius: CGFloat
    let around: Double
    let color: Color
    let hovered: Bool

    var body: some View {
        let slotPoint = pip.slot.map { PipArc.position(slot: $0, slots: frame.slots, centre: centre, radius: radius, around: around) } ?? centre
        // Spawn (design: Pip Sounds): hidden at the centre while the rim stretches toward the slot; at the snap it
        // appears just inside the slot as a droplet stretched along the pull, then springs round into the slot.
        let angle = atan2(slotPoint.y - centre.y, slotPoint.x - centre.x)
        let snapPoint = CGPoint(x: centre.x + cos(angle) * radius * 0.92, y: centre.y + sin(angle) * radius * 0.92)
        let position = pip.atCenter || pip.pulling || pip.slot == nil ? centre : pip.snapping ? snapPoint : slotPoint
        let base: CGFloat = pip.atCenter || pip.pulling ? 0.15 : pip.flaring ? 2.4 : pip.hopping ? 1.45 : hovered ? 1.3 : 1
        let stretch = pip.snapping ? CGSize(width: 2.6, height: 0.55) : CGSize(width: base, height: base)
        let shown = !(pip.slot == nil || frame.merged || pip.pulling)
        // The snap is instant (no animation into it); everything after springs.
        let move: Animation? = pip.snapping ? nil
            : frame.merged ? .easeIn(duration: 0.45).delay(Double(pip.rank) * 0.05)
            : .spring(response: 0.6, dampingFraction: 0.62)
        let bounce: Animation? = pip.snapping ? nil
            : pip.shake != 0 ? .linear(duration: 0.05) : .spring(response: 0.45, dampingFraction: 0.42)
        Circle()
            .fill(pip.flaring ? Color.white : color)
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(color, lineWidth: 1.2).padding(-2.5).opacity(hovered ? 1 : 0))
            .shadow(color: pip.flaring ? .white : color.opacity(0.8), radius: pip.flaring ? 6 : 3)
            .scaleEffect(x: stretch.width, y: stretch.height)
            .rotationEffect(.radians(pip.snapping ? angle : 0))
            .animation(bounce, value: stretch)
            .animation(bounce, value: pip.snapping)
            .offset(x: pip.shake, y: pip.hopping ? -9 : 0)
            .animation(bounce, value: pip.shake)
            .animation(bounce, value: pip.hopping)
            .opacity(shown ? 1 : 0)
            .position(position)
            .animation(move, value: position)
            .animation(pip.snapping ? nil : frame.merged ? move : .easeOut(duration: 0.35), value: shown)
            .animation(.easeOut(duration: 0.4), value: pip.flaring)
    }
}

/// The peek card shown under a hovered pip.
struct PipCardView: View {
    let session: Session
    @ObservedObject var model: SessionsModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            SessionRow(session: session, now: context.date,
                       palette: model.palette)
        }
        .padding(4)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date
    let palette: OrbPalette
    /// 0 → 1 as the row cascades in (text decodes like a toast); 1 when settled.
    var entrance: Double = 1

    var body: some View {
        // Top-aligned so the pip and the times sit on the title's line, however tall the row grows (chips).
        HStack(alignment: .top, spacing: 12) {
            Group {
                // A pip, coloured like the ones under the orb.
                let color = session.pipColor(in: palette)
                Circle().fill(color).frame(width: 9, height: 9)
                    .shadow(color: color.opacity(session.tone == .idle ? 0 : 0.8), radius: 4)
            }
            .frame(width: 26, height: 17)   // the title's line height
            VStack(alignment: .leading, spacing: 2) {
                Text(entrance < 1 ? ToastDecode.text(session.displayName, progress: entrance, seed: session.id.hashValue & 0xffff,
                                                     tick: Int(CACurrentMediaTime() / 0.045)) : session.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.reviewReady ? "Ready for review" : session.detail.isEmpty ? "Idle" : session.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(session.tone.color(in: palette))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !session.links.isEmpty {
                    LinkChips(links: session.links).padding(.top, 6)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ElapsedFormat.string(now.timeIntervalSince(session.stateSince)))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
                if let tokens = session.tokens {
                    Text(TokenFormat.string(tokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .help("Context size")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(entrance)
        .offset(x: (1 - entrance) * 6)
    }
}

/// When the hover card opened or started closing, and which edge faces the orb.
final class CardMotionModel: ObservableObject {
    @Published var shownAt: Double = 0
    @Published var hiddenAt: Double?
    /// The card hangs below the orb, so it unfolds from its top edge.
    @Published var fromTop = true
}

struct SessionListView: View {
    @ObservedObject var model: SessionsModel
    @ObservedObject var motion: CardMotionModel
    let onSelect: () -> Void

    var body: some View {
        // Animate at display rate while popping in or out, otherwise just tick the timers once a second.
        let settled = motion.hiddenAt == nil && CACurrentMediaTime() - motion.shownAt > 0.9
        TimelineView(.animation(minimumInterval: settled ? 1 : nil, paused: false)) { context in
            let now = CACurrentMediaTime()
            let age = now - motion.shownAt
            let pose = motion.hiddenAt.map { CardMotion.disappear(age: now - $0) } ?? CardMotion.appear(age: age)
            card(now: context.date, age: motion.hiddenAt == nil ? age : 10)
                .mask { CardReveal(reveal: pose.reveal, fromTop: motion.fromTop) }
                .scaleEffect(pose.scale, anchor: motion.fromTop ? .top : .bottom)
                .offset(y: (motion.fromTop ? -1 : 1) * pose.offset)
                .opacity(pose.opacity)
        }
    }

    private func card(now: Date, age: Double) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(SessionStore.sorted(model.sessions).enumerated()), id: \.element.id) { index, session in
                SessionRow(session: session, now: now,
                           palette: model.palette, entrance: CardMotion.row(index, age: age))
                    .onTapGesture(perform: onSelect)
            }
            if model.today != nil || model.usage != nil {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 4)
                TodayFooter(summary: model.today, usage: model.usage, palette: model.palette, now: now)
            }
        }
        .padding(8)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// The card's reveal: an ellipse centred on the edge facing the orb, growing until it covers the whole card.
private struct CardReveal: View {
    let reveal: Double
    let fromTop: Bool

    var body: some View {
        GeometryReader { geo in
            if reveal >= 1 {
                Rectangle()
            } else {
                Ellipse()
                    .frame(width: geo.size.width * 2.4 * reveal, height: geo.size.height * 2.6 * reveal)
                    .position(x: geo.size.width / 2, y: fromTop ? 0 : geo.size.height)
            }
        }
    }
}

struct TodayFooter: View {
    let summary: DailyActivity.Summary?
    var usage: UsageReading?
    var palette: OrbPalette = .agentsView
    var now = Date()

    var body: some View {
        HStack(spacing: usage == nil ? 6 : 3) {
            if let summary {
                Text("Today").foregroundStyle(Color.white.opacity(0.6))
                Text("·")
                // "working" makes way for the usage numbers so the line fits the card.
                Text(DurationFormat.string(summary.working) + (usage == nil ? " working" : ""))
                Text("·")
                Text("\(summary.sessions) \(summary.sessions == 1 ? "session" : "sessions")").truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let usage {
                Text(UsageFormat.percent(usage.left(at: now))).foregroundStyle(levelColor(usage.level(at: now)))
                    .fixedSize()
                Text("·")
                Text(DurationFormat.string(usage.timeLeft(at: now))).fixedSize()
            }
        }
        .lineLimit(1)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.4))
        .padding(.horizontal, usage == nil ? 10 : 6)
        .padding(.vertical, 6)
    }
    private func levelColor(_ level: UsageLevel) -> Color {
        switch level {
        case .ok: Color.white.opacity(0.4)
        case .low: BubbleState.needs.color(in: palette)
        case .critical: BubbleState.error.color(in: palette)
        }
    }
}

/// Hosting view that clicks fall straight through, for decoration drawn over the orb.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hosting view that takes the first click even though its panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A session's issue, pull request and artifact chips; clicking one opens it.
struct LinkChips: View {
    let links: [SessionLink]

    var body: some View {
        // Status words when they fit on one line; otherwise just their icons.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { ForEach(links, id: \.self) { LinkChip(link: $0, compact: false) } }
            HStack(spacing: 5) { ForEach(links, id: \.self) { LinkChip(link: $0, compact: true) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Set when a chip opened its link, so a click the island replays to its content doesn't also focus the terminal.
enum ChipClick {
    static var handled = false
}

private struct LinkChip: View {
    let link: SessionLink
    let compact: Bool
    @State private var hover = false

    private static let green = Color(red: 0.42, green: 0.85, blue: 0.55)
    private static let red = Color(red: 1, green: 0.42, blue: 0.42)
    private static let amber = Color(red: 1, green: 0.78, blue: 0.35)
    private static let violet = Color(red: 0.66, green: 0.55, blue: 1)
    private static let grey = Color.white.opacity(0.45)

    private var icon: String {
        switch link.kind {
        case .issue: link.status?.state == .closed ? "checkmark.circle" : "smallcircle.filled.circle"
        case .artifact: "doc.text"
        case .pr:
            switch link.status?.state {
            case .merged: "arrow.triangle.merge"
            case .closed: "xmark.circle"
            case .draft: "pencil.circle"
            default: "arrow.triangle.pull"
            }
        }
    }

    private var tint: Color {
        switch link.kind {
        case .issue: link.status?.state == .closed ? Self.violet : Self.green
        case .artifact: Color(red: 0.95, green: 0.7, blue: 0.45)
        case .pr:
            switch link.status?.state {
            case .merged: Self.violet
            case .closed, .draft: Self.grey
            default: Self.violet
            }
        }
    }

    /// A pull request's status in a word or two, after its number: whatever needs attention first. An issue's: open or closed.
    private var statusText: (String, Color)? {
        guard let s = link.status else { return nil }
        if link.kind == .issue { return s.state == .closed ? ("Closed", Self.violet) : ("Open", Self.grey) }
        switch s.state {
        case .merged: return ("Merged", Self.violet)
        case .closed: return ("Closed", Self.grey)
        case .draft, .open: break
        }
        if s.checks == .failing { return ("Checks fail", Self.red) }
        if s.review == .changesRequested { return ("Changes requested", Self.amber) }
        if s.checks == .pending { return ("Checks running", Self.amber) }
        if s.state == .draft { return ("Draft", Self.grey) }
        if s.review == .approved { return ("Approved", Self.green) }
        if s.checks == .passing { return ("Checks pass", Self.green) }
        return ("Open", Self.grey)
    }

    /// The same status as a glyph, for when the words don't fit (merged, closed and draft show in the chip's icon).
    private var statusIcon: (String, Color)? {
        guard link.kind == .pr, let s = link.status, s.state == .open || s.state == .draft else { return nil }
        if s.checks == .failing { return ("xmark", Self.red) }
        if s.review == .changesRequested { return ("exclamationmark.bubble.fill", Self.amber) }
        if s.checks == .pending { return ("circle.dotted", Self.amber) }
        if s.review == .approved { return ("checkmark.seal.fill", Self.green) }
        if s.checks == .passing { return ("checkmark", Self.green) }
        return nil
    }

    private var summary: String {
        guard let s = link.status else { return link.url.absoluteString }
        let state = switch s.state { case .open: "Open"; case .draft: "Draft"; case .merged: "Merged"; case .closed: "Closed" }
        guard s.state == .open || s.state == .draft else { return state }
        let checks = switch s.checks { case .passing: " · checks passing"; case .failing: " · checks failing"
                                       case .pending: " · checks running"; case .none: "" }
        let review = switch s.review { case .approved: " · approved"; case .changesRequested: " · changes requested"; case .none: "" }
        return state + checks + review
    }

    var body: some View {
        Button {
            ChipClick.handled = true
            NSWorkspace.shared.open(link.url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(link.label).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                    .foregroundStyle(Color.white.opacity(hover ? 1 : 0.85))
                    .frame(maxWidth: compact ? 90 : 130, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if compact {
                    if let (name, color) = statusIcon {
                        Image(systemName: name).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
                    }
                } else if let (text, color) = statusText {
                    Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color).lineLimit(1).fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.55)))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(hover ? 0.22 : 0.12), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(summary)
    }
}
