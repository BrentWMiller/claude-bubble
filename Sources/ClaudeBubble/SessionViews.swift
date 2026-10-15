import AppKit
import ClaudeBubbleCore
import SwiftUI

extension BubbleState {
    /// The color the orb reads as in this state, for pips and fallbacks.
    var accent: Color {
        let c = swatch
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var detailColor: Color {
        switch self {
        case .needs: Color(red: 0xf2 / 255, green: 0xd0 / 255, blue: 0x4a / 255)
        case .error: Color(red: 0xe8 / 255, green: 0x55 / 255, blue: 0x4f / 255)
        case .idle, .working: Color.white.opacity(0.55)
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
                    .fill(state.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: state.accent.opacity(0.8), radius: 3)
            }
            if layout.overflow > 0 {
                Text("+\(layout.overflow)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: layout)
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date
    let snapshot: NSImage?
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().frame(width: 40, height: 40)
                } else {
                    Circle().fill(session.state.accent).frame(width: 18, height: 18)
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
                    .foregroundStyle(session.state.detailColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Text(ElapsedFormat.string(now.timeIntervalSince(session.stateSince)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(highlighted ? 0.06 : 0)))
        .contentShape(Rectangle())
    }
}

struct SessionListView: View {
    @ObservedObject var model: SessionsModel
    let snapshots: [BubbleState: NSImage]
    let onSelect: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 2) {
                ForEach(Array(SessionStore.sorted(model.sessions).enumerated()), id: \.element.id) { index, session in
                    SessionRow(session: session, now: context.date, snapshot: snapshots[session.state], highlighted: index == 0)
                        .onTapGesture(perform: onSelect)
                }
            }
            .padding(8)
        }
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
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
