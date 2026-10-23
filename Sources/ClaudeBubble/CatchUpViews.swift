import AppKit
import ClaudeBubbleCore
import HookCore
import SwiftUI

/// How long you were away: "42 min", "1h 11m".
private func awayLabel(since: Date, now: Date) -> String {
    let mins = max(1, Int(now.timeIntervalSince(since) / 60))
    return mins < 60 ? "\(mins) min" : "\(mins / 60)h \(mins % 60)m"
}

/// How long ago, short: "18m", "2h", "now".
private func agoLabel(since: Date, now: Date) -> String {
    let mins = Int(now.timeIntervalSince(since) / 60)
    if mins < 1 { return "now" }
    return mins < 60 ? "\(mins)m" : "\(mins / 60)h"
}

/// "While you were away": atop the session list until you've opened the catch-up (design: Catch-up mock).
struct CatchUpBanner: View {
    @ObservedObject var model: SessionsModel
    let now: Date

    var body: some View {
        if let catchUp = model.catchUp {
            let sessions = catchUp.items.compactMap { model.byID[$0.sessionID] }
            Button {
                ChipClick.handled = true
                model.openCatchUp()
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        ForEach(sessions.prefix(6), id: \.id) { s in
                            Circle().fill(s.state.color(in: model.palette)).frame(width: 6, height: 6)
                        }
                    }
                    (Text("While you were away").fontWeight(.semibold).foregroundColor(.white)
                        + Text(" · \(awayLabel(since: catchUp.leftAt, now: now))").foregroundColor(Color.white.opacity(0.45)))
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(sessions.count) \(sessions.count == 1 ? "update" : "updates") ›")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(CatchUpColors.link)
                }
                .padding(.horizontal, 12)
                .frame(height: AwayLayout.bannerHeight - 6)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
    }
}

enum CatchUpColors {
    static let link = Color(red: 0.55, green: 0.8, blue: 1)
    static let dim = Color.white.opacity(0.45)
}

/// The catch-up in place of the list: what changed while you were away, by where each session stands now.
struct CatchUpView: View {
    @ObservedObject var model: SessionsModel
    /// The list's width.
    let width: CGFloat
    let now: Date

    var body: some View {
        let groups = model.catchUpGroups()
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { group, items in
                        groupHeading(group, count: items.count)
                        ForEach(items, id: \.sessionID) { item in
                            if let s = model.byID[item.sessionID] { CatchUpRow(model: model, session: s, item: item, width: width, now: now) }
                        }
                    }
                    if model.catchUpSummaries {
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.top, 6)
                        Text("Summaries by Claude Haiku · each line only knows its own session")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.35))
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: width, height: model.catchUpHeight(width: width), alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("While you were away").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            if let leftAt = model.catchUp?.leftAt {
                Text(" · \(awayLabel(since: leftAt, now: now))").font(.system(size: 15)).foregroundStyle(CatchUpColors.dim)
            }
            Spacer()
            Button {
                ChipClick.handled = true
                model.closeCatchUp()
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.6))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 6)
        .frame(height: 44)
        .padding(.bottom, 8)
    }

    private func groupHeading(_ group: AwayGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(group.title).kerning(1.2).foregroundStyle(color(group))
            Text("\(count)").foregroundStyle(Color.white.opacity(0.35))
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .frame(height: 30, alignment: .center)
    }

    private func color(_ group: AwayGroup) -> Color {
        let state: BubbleState = switch group {
        case .needsYou: .needs
        case .finished: .idle
        case .failed: .error
        case .stillWorking: .working
        }
        return state.color(in: model.palette)
    }
}

/// One session in the catch-up: its line, when it was written, its chips, and for one that needs you, what to do.
private struct CatchUpRow: View {
    @ObservedObject var model: SessionsModel
    let session: Session
    let item: AwayItem
    let width: CGFloat
    let now: Date
    @State private var holding = false

    private var accent: Color { BubbleState.needs.color(in: model.palette) }
    private var needsYou: Bool { session.state == .needs }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(session.state.color(in: model.palette)).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(session.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    if needsYou {
                        Text(agoLabel(since: session.stateSince, now: now))
                            .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(accent)
                    }
                }
                line
                HStack(spacing: 8) {
                    if case let .written(_, at) = item.line {
                        Text("written \(agoLabel(since: at, now: now) == "now" ? "just now" : agoLabel(since: at, now: now) + " ago")")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.white.opacity(0.35))
                    }
                    if !session.links.isEmpty { LinkChips(links: session.links) }
                }
                if needsYou { actions.padding(.top, 4) }
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var line: some View {
        if case .pending = item.line {
            TimelineView(.animation) { t in
                let a = 0.08 + 0.06 * sin(t.date.timeIntervalSinceReferenceDate * 4)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(a)).frame(height: 12)
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(a)).frame(width: 140, height: 12)
                }
            }
            .frame(height: 30)
        } else if let text = item.line.text, !text.isEmpty {
            Text(text).font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.8))
                .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        if let request = model.approval(for: session), let decide = model.decide {
            ApprovalCard(request: request, accent: accent, width: SessionsModel.catchUpCardWidth(width),
                         onAnswer: model.answer.map { answer in { answer(request, $0) } },
                         onDecide: { decide(request, $0) })
        } else {
            HStack(spacing: 8) {
                Button {
                    ChipClick.handled = true
                    model.openSession?(session)
                } label: {
                    Text("Open terminal").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let holdTalk = model.holdTalk, model.talkEnabled {
                    HStack(spacing: 6) {
                        MicGlyph().frame(width: 12, height: 12)
                        Text(holding ? "Listening…" : "Hold to reply").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(CatchUpColors.link))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            ChipClick.handled = true
                            if !holding { holding = true; holdTalk(session, true) }
                        }
                        .onEnded { _ in
                            ChipClick.handled = true
                            holding = false
                            holdTalk(session, false)
                        })
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { MicTargets.frames["catchup:" + session.id] = $0 }
                    .onDisappear {
                        MicTargets.frames["catchup:" + session.id] = nil
                        if holding { holding = false; holdTalk(session, false) }
                    }
                }
            }
            .frame(height: 34)
        }
    }
}
