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

struct PipsView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        let layout = PipLayout.pips(for: model.sessions)
        HStack(spacing: 5) {
            ForEach(Array(layout.states.enumerated()), id: \.offset) { _, state in
                Circle()
                    .fill(state.color(in: model.palette))
                    .frame(width: 6, height: 6)
                    .shadow(color: state.color(in: model.palette).opacity(0.8), radius: 3)
                    .transition(.scale.combined(with: .opacity))
            }
            if layout.overflow > 0 {
                Text("+\(layout.overflow)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(model.present ? 1 : 0.2)
        .opacity(model.present ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: layout)
        // Spring in alongside the orb's overshoot; drop out as fast as the orb vanishes.
        .animation(model.present ? .spring(response: 0.45, dampingFraction: 0.5) : .easeIn(duration: 0.15), value: model.present)
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
                Text(session.detail.isEmpty ? "Idle" : session.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(session.state.detailColor(in: palette))
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
