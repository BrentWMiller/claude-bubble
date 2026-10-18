import AppKit
import ClaudeBubbleCore
import HookCore
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
    /// sessions that went quiet without finishing take the palette's Idle colour.
    func color(in palette: OrbPalette) -> Color {
        let state: BubbleState
        switch self {
        case .attention: state = .needs
        case .error: state = .error
        case .working: state = .working
        case .completed: state = .idle
        case .idle:
            let c = palette.quiet
            return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
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
        guard let session = model.byID[pip.id] else {
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
            let asking = model.approval(for: session)
            SessionRow(session: session, now: context.date,
                       palette: model.palette, approval: asking,
                       onDecide: asking.map { request in { model.decide?(request, $0) } })
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
    var pinned = false
    /// Pins or unpins the session (no pin button without it).
    var onPin: (() -> Void)?
    /// The permission prompt it's waiting on, with Allow and Deny (none without `onDecide`): in full on a card
    /// under the row when `expanded` (the most recent request), else as a small Deny | Allow pill.
    var approval: ApprovalRequest?
    var expanded = false
    /// The row's width, for laying out its approval card.
    var width: CGFloat = 0
    var onDecide: ((ApprovalBehavior) -> Void)?
    @State private var hover = false

    /// The card's width under a row: the row less its padding and the pip's column.
    static func cardWidth(row: CGFloat) -> CGFloat { row - 20 - 38 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let approval, let onDecide, expanded {
                ApprovalCard(request: approval, accent: BubbleState.needs.color(in: palette),
                             width: Self.cardWidth(row: width), onDecide: onDecide)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .opacity(entrance)
        .offset(x: (1 - entrance) * 6)
    }

    private var header: some View {
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
                Text(expanded && approval != nil ? approval!.headline
                     : session.reviewReady ? "Ready for review" : session.detail.isEmpty ? "Idle" : session.detail)
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
                HStack(spacing: 6) {
                    // Shown on hover, and always once pinned.
                    if let onPin, pinned || hover {
                        Button {
                            ChipClick.handled = true   // the island's click goes to the pin, not the terminal
                            onPin()
                        } label: {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(45))
                                .foregroundStyle(Color.white.opacity(pinned ? 0.75 : 0.4))
                                .frame(width: 14, height: 14)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(pinned ? "Unpin" : "Pin to the top")
                    }
                    Text(ElapsedFormat.string(now.timeIntervalSince(session.stateSince)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                if let approval, let onDecide, !expanded {
                    ApprovalSplit(request: approval, accent: BubbleState.needs.color(in: palette), onDecide: onDecide)
                } else if let tokens = session.tokens {
                    Text(TokenFormat.string(tokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.28))
                        .help("Context size")
                }
            }
        }
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
    static let width: CGFloat = 300
    @ObservedObject var model: SessionsModel
    @ObservedObject var motion: CardMotionModel
    let onSelect: (Session) -> Void
    /// Done popping in (tick once a second) or out (stop).
    @State private var settled = false
    @State private var gone = false

    var body: some View {
        // Animate at display rate while popping in or out, otherwise just tick the timers once a second; nothing once
        // it's gone. Set from a task, not worked out in the body, which may not run again for a long while.
        TimelineView(.animation(minimumInterval: settled ? 1 : nil, paused: gone)) { context in
            let now = CACurrentMediaTime()
            let age = now - motion.shownAt
            let pose = motion.hiddenAt.map { CardMotion.disappear(age: now - $0) } ?? CardMotion.appear(age: age)
            card(now: context.date, age: motion.hiddenAt == nil ? age : 10)
                .mask { CardReveal(reveal: pose.reveal, fromTop: motion.fromTop) }
                .scaleEffect(pose.scale, anchor: motion.fromTop ? .top : .bottom)
                .offset(y: (motion.fromTop ? -1 : 1) * pose.offset)
                .opacity(pose.opacity)
        }
        .task(id: [motion.shownAt, motion.hiddenAt ?? -1]) {
            settled = false
            gone = false
            try? await Task.sleep(nanoseconds: motion.hiddenAt == nil ? 900_000_000 : 1_000_000_000)
            guard !Task.isCancelled else { return }
            if motion.hiddenAt == nil { settled = true } else { gone = true }
        }
    }

    private func decide(_ session: Session) -> ((ApprovalBehavior) -> Void)? {
        guard let request = model.approval(for: session) else { return nil }
        return { model.decide?(request, $0) }
    }

    private func card(now: Date, age: Double) -> some View {
        VStack(spacing: 2) {
            ForEach(Array(model.sorted.enumerated()), id: \.element.id) { index, session in
                SessionRow(session: session, now: now,
                           palette: model.palette, entrance: CardMotion.row(index, age: age),
                           pinned: model.pinned.contains(session.id), onPin: { model.togglePin(session.id) },
                           approval: model.approval(for: session),
                           expanded: model.approval(for: session)?.id == model.expandedApproval?.id,
                           width: SessionListView.width - 16, onDecide: decide(session))
                    .onTapGesture { onSelect(session) }
            }
            if model.today != nil || model.usage != nil {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 4)
                TodayFooter(summary: model.today, usage: model.usage, palette: model.palette, now: now)
            }
        }
        .padding(8)
        .frame(width: Self.width)
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

/// A waiting permission prompt in full (design: Approve / Deny 1a, 2a, 2b): Claude's reason, the command or the
/// diff in a code block, then Deny and Allow. Laid out to ApprovalCardLayout's exact measurements, so the island can
/// size itself to fit. Clicks only: no keyboard shortcut or default button, so nothing is approved by a stray key.
struct ApprovalCard: View {
    let request: ApprovalRequest
    let accent: Color
    let width: CGFloat
    let onDecide: (ApprovalBehavior) -> Void

    private typealias L = ApprovalCardLayout

    var body: some View {
        VStack(alignment: .leading, spacing: L.spacing) {
            if let reason = request.reason {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .lineLimit(2).truncationMode(.tail)
                    .frame(width: width, height: CGFloat(L.reasonLines(request, width: width)) * L.reasonLine, alignment: .topLeading)
            }
            block
            HStack(spacing: 8) {
                ApprovalButton(title: "Deny", filled: false, accent: accent) { onDecide(.deny) }
                ApprovalButton(title: request.allowTitle, filled: true, accent: accent) { onDecide(.allow) }
            }
            .frame(height: L.buttonHeight)
        }
        .frame(width: width, alignment: .leading)
    }

    private var block: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(request.blockLabel)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .kerning(request.diff == nil ? 0.8 : 0)
                    .foregroundStyle(Color.white.opacity(request.diff == nil ? 0.45 : 0.75))
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if let diff = request.diff {
                    (Text("+\(diff.added)").foregroundColor(Self.added) + Text(" -\(diff.removed)").foregroundColor(Self.removed))
                        .font(.system(size: 10.5, design: .monospaced))
                } else {
                    Text((request.cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.32))
                        .lineLimit(1).truncationMode(.head)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: L.blockHeader)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
            if let diff = request.diff { diffBody(diff) } else { code }
        }
        .frame(width: width, height: L.blockHeight(request, width: width), alignment: .top)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .help(request.detail)
    }

    private var code: some View {
        let lines = L.codeLines(request, width: width)
        let text = request.tool == "Bash" ? Text("$ ").foregroundColor(accent) + Text(request.detail) : Text(request.detail)
        return text
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.9))
            .lineSpacing(2)
            .lineLimit(lines).truncationMode(.tail)
            .frame(width: width - 20, height: CGFloat(lines) * L.codeLine, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, L.blockPadding / 2)
    }

    static let added = Color(red: 0.42, green: 0.85, blue: 0.5)
    static let removed = Color(red: 0.98, green: 0.45, blue: 0.42)

    private func diffBody(_ diff: ApprovalDiff) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                let (mark, color, fill): (String, Color, Color) = switch line.kind {
                case .context: ("  ", Color.white.opacity(0.45), .clear)
                case .removed: ("- ", Self.removed, Self.removed.opacity(0.13))
                case .added: ("+ ", Self.added, Self.added.opacity(0.12))
                }
                Text(mark + line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(width: width, height: L.diffLine, alignment: .leading)
                    .background(fill)
            }
            if diff.hidden > 0 {
                Text("+\(diff.hidden) more line\(diff.hidden == 1 ? "" : "s")")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.horizontal, 10)
                    .frame(width: width, height: L.moreLine, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One of the card's buttons: Deny outlined, Allow filled with the theme's needs-you colour.
private struct ApprovalButton: View {
    let title: String
    let filled: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button {
            ChipClick.handled = true   // the island's click goes to the button, not the terminal
            action()
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(filled ? Color.black : Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(filled ? accent : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(filled ? 0 : 0.14), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// Deny | Allow in one small pill, for a row that isn't the one expanded (design: 1b).
struct ApprovalSplit: View {
    let request: ApprovalRequest
    let accent: Color
    let onDecide: (ApprovalBehavior) -> Void

    var body: some View {
        HStack(spacing: 0) {
            part("Deny", filled: false) { onDecide(.deny) }
            part("Allow", filled: true) { onDecide(.allow) }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .help("\(request.headline): \(request.detail)")
    }

    private func part(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            ChipClick.handled = true
            action()
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(filled ? Color.black : Color.white.opacity(0.8))
                .padding(.horizontal, 9)
                .frame(height: 16)
                .background(Capsule().fill(filled ? accent : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct LinkChip: View {
    let link: SessionLink
    let compact: Bool
    @State private var hover = false
    @State private var cardTimer: Timer?
    @State private var owner = UUID()
    @State private var place = ScreenFrameReader.Box()
    @Environment(\.isSnapshot) private var snapshot

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
        if link.kind == .issue { return s.state == .closed ? ("Closed", Self.violet) : ("Open", Self.green) }
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
            .background { if !snapshot { ScreenFrameReader(box: place) } }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
            cardTimer?.invalidate()
            cardTimer = nil
            guard link.kind != .artifact, LinkPreviewFetcher.available else { return }
            if inside {
                // A short dwell, so sweeping across chips doesn't flash cards (or run gh).
                cardTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [link, icon, tint, statusText, owner, place] _ in
                    guard let rect = ScreenFrameReader.screenRect(place) else { return }
                    LinkPreviewFetcher.shared.load(link)
                    LinkCardController.shared.show(link, icon: icon, tint: tint, status: statusText, from: rect, owner: owner)
                }
            } else {
                LinkCardController.shared.hide(owner: owner)
            }
        }
        .onDisappear { cardTimer?.invalidate() }
        .help(LinkPreviewFetcher.available && link.kind != .artifact ? "" : summary)
    }
}

/// A pull request's or issue's hover card: what it is and its status, its title, then labels, who and how big, and its
/// checks and review.
struct LinkPreviewCard: View {
    let link: SessionLink
    let preview: LinkPreview?
    let icon: String
    let tint: Color
    let status: (String, Color)?

    private static let green = Color(red: 0.42, green: 0.85, blue: 0.55)
    private static let red = Color(red: 1, green: 0.42, blue: 0.42)
    private static let amber = Color(red: 1, green: 0.78, blue: 0.35)
    private static let dim = Color.white.opacity(0.45)
    private static let soft = Color.white.opacity(0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                Text("\(link.kind == .issue ? "Issue" : "PR") \(link.label)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Self.dim)
                Spacer(minLength: 8)
                if let (text, color) = status {
                    Text(text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(color)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.14)))
                }
            }
            if let p = preview {
                Text(p.title).font(.system(size: 13.5, weight: .bold)).foregroundStyle(.white)
                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                labels(p)
                VStack(alignment: .leading, spacing: 5) {
                    meta(p)
                    checks(p)
                }
            } else {
                // Loading: the title's place, shimmering.
                TimelineView(.animation) { t in
                    let a = 0.08 + 0.06 * sin(t.date.timeIntervalSinceReferenceDate * 4)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(a)).frame(width: 230, height: 13)
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(a)).frame(width: 150, height: 13)
                    }
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .frame(width: 300, alignment: .leading)
        .background(Color(red: 0.105, green: 0.105, blue: 0.115))
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func labels(_ p: LinkPreview) -> some View {
        if !p.labels.isEmpty {
            HStack(spacing: 5) {
                ForEach(p.labels.prefix(3), id: \.name) { l in
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: l.color)).frame(width: 6, height: 6)
                        Text(l.name).font(.system(size: 11)).foregroundStyle(Self.soft).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                }
            }
        }
    }

    /// "author · +90 −19 · 3 files", or an issue's "author · 1 comment".
    @ViewBuilder private func meta(_ p: LinkPreview) -> some View {
        let dot = Text("  ·  ").foregroundStyle(Self.dim)
        var line = p.author.map { Text($0).foregroundStyle(Self.soft) }
        let add = { (t: Text) in line = line.map { $0 + dot + t } ?? t }
        if let a = p.additions, let d = p.deletions {
            let _ = add(Text("+\(a)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.green)
                        + Text(" ") + Text("-\(d)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.red))
        }
        if let f = p.changedFiles { let _ = add(Text("\(f) file\(f == 1 ? "" : "s")").foregroundStyle(Self.dim)) }
        if let c = p.comments { let _ = add(Text("\(c) comment\(c == 1 ? "" : "s")").foregroundStyle(Self.dim)) }
        if let line { line.font(.system(size: 12)).lineLimit(1) }
    }

    /// Failed checks by name (they matter most), then "✓ 16 · ◌ 2 · Approved by …".
    @ViewBuilder private func checks(_ p: LinkPreview) -> some View {
        if !p.failed.isEmpty {
            let shown = p.failed.prefix(3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, name in
                    Text("✕ \(name)").foregroundStyle(Self.red)
                }
                if p.failed.count > shown.count { Text("+\(p.failed.count - shown.count) more failed").foregroundStyle(Self.red) }
            }
            .font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        let dot = Text("  ·  ").foregroundStyle(Self.dim)
        let parts = [
            p.passed > 0 ? Text("✓ \(p.passed)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.green) : nil,
            p.running > 0 ? Text("◌ \(p.running)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.amber) : nil,
            p.review.map { Text($0).foregroundStyle(Self.dim) },
        ].compactMap { $0 }
        if let first = parts.first {
            parts.dropFirst().reduce(first) { $0 + dot + $1 }.font(.system(size: 12)).lineLimit(1)
        }
    }
}

private extension Color {
    /// GitHub's "d73a4a" label colours.
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
