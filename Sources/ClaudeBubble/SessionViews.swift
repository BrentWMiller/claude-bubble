import AppKit
import ClaudeBubbleCore
import SwiftUI

extension BubbleState {
    /// The color the orb reads as in this state, for pips, wells and fallbacks.
    func color(in palette: OrbPalette) -> Color {
        let c = palette[self].swatch
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    /// Needs and error rows take their state's color; the rest stay quiet.
    func detailColor(in palette: OrbPalette) -> Color {
        switch self {
        case .needs, .error: color(in: palette)
        case .idle, .working: Color.white.opacity(0.55)
        }
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
    /// The agents view's colours, regardless of the orb's palette.
    var color: Color {
        switch self {
        case .attention: Color(red: 0xf0 / 255, green: 0xa0 / 255, blue: 0x50 / 255)
        case .error: Color(red: 0xe8 / 255, green: 0x55 / 255, blue: 0x4f / 255)
        case .working: Color(red: 0xb0 / 255, green: 0x8c / 255, blue: 1)
        case .completed: Color(red: 0x5f / 255, green: 0xd9 / 255, blue: 0x8a / 255)
        case .idle: Color.white.opacity(0.45)
        }
    }
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
                           color: (pip.review ? BubbleState.needs : pip.state).color(in: model.palette),
                           hovered: model.hoveredPip == pip.id)
                }
                if frame.overflow > 0 {
                    Text("+\(frame.overflow)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .position(PipArc.position(slot: frame.slots - 1, slots: frame.slots, centre: centre, radius: radius))
                        .opacity(frame.merged ? 0 : 1)
                        .animation(.easeOut(duration: 0.3), value: frame.merged)
                }
            }
        }
        .opacity(model.present && model.pips.visible ? 1 : 0)
        .animation(model.present ? .spring(response: 0.45, dampingFraction: 0.5) : .easeIn(duration: 0.15), value: model.present)
    }
}

private struct PipDot: View {
    let pip: PipFrame
    let frame: PipsFrame
    let centre: CGPoint
    let radius: CGFloat
    let color: Color
    let hovered: Bool

    var body: some View {
        let slotPoint = pip.slot.map { PipArc.position(slot: $0, slots: frame.slots, centre: centre, radius: radius) } ?? centre
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
            SessionRow(session: session, now: context.date, snapshot: model.snapshots[session.state],
                       palette: model.palette, highlighted: false)
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
    let snapshot: NSImage?
    let palette: OrbPalette
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().frame(width: 40, height: 40)
                } else {
                    Circle().fill(session.state.color(in: palette)).frame(width: 18, height: 18)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.reviewReady ? "Ready for review" : session.detail.isEmpty ? "Idle" : session.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(session.tone.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(highlighted ? 0.06 : 0)))
        .contentShape(Rectangle())
    }
}

struct SessionListView: View {
    @ObservedObject var model: SessionsModel
    let onSelect: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 2) {
                ForEach(Array(SessionStore.sorted(model.sessions).enumerated()), id: \.element.id) { index, session in
                    SessionRow(session: session, now: context.date, snapshot: model.snapshots[session.state],
                               palette: model.palette, highlighted: index == 0)
                        .onTapGesture(perform: onSelect)
                }
                if let today = model.today {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 4)
                    TodayFooter(summary: today)
                }
            }
            .padding(8)
        }
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

struct TodayFooter: View {
    let summary: DailyActivity.Summary

    var body: some View {
        HStack(spacing: 6) {
            Text("Today").foregroundStyle(Color.white.opacity(0.6))
            Text("·")
            Text("\(DurationFormat.string(summary.working)) working")
            Text("·")
            Text("\(summary.sessions) \(summary.sessions == 1 ? "session" : "sessions")")
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.4))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
