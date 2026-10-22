import AppKit
import ClaudeBubbleCore
import Combine
import HookCore

/// Live sessions, plus the current palette, shared by the pips and the hover list.
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = [] {
        didSet { resort() }
    }
    /// Sessions you pinned (by id): they lead the island and the list. Kept across restarts.
    @Published private(set) var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: SessionsModel.pinnedKey) ?? []) {
        didSet { resort() }
    }
    static let pinnedKey = "pinnedSessions"

    func togglePin(_ id: String) {
        if pinned.contains(id) {
            pinned.remove(id)
        } else {
            // Pins of sessions that have ended go when a new one is added (an ended session never comes back).
            pinned = pinned.filter { byID[$0] != nil }.union([id])
        }
        UserDefaults.standard.set(Array(pinned), forKey: Self.pinnedKey)
    }

    private func resort() {
        sorted = SessionStore.sorted(sessions, pinned: pinned)
        byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        linkedRows = sorted.prefix(IslandLayout.maxRows).filter { !$0.links.isEmpty }.count
        pipInputs = sessions.map { PipInput(id: $0.id, state: $0.state, review: $0.reviewReady) }
    }
    /// `sessions`, most urgent first (sorted once per change, not per view per frame).
    private(set) var sorted: [Session] = []
    private(set) var byID: [String: Session] = [:]
    /// `IslandLayout.linkedRows(sessions)`, and the pip choreographer's input: worked out once per change, not on
    /// every 20Hz tick.
    private(set) var linkedRows = 0
    private(set) var pipInputs: [PipInput] = []
    @Published var palette: OrbPalette = .agentsView
    /// Mirrors the orb's appear/vanish so the pips pop in and out with it.
    @Published var present = false
    /// Today's working time and session count, refreshed while the list is open.
    @Published var today: DailyActivity.Summary?
    /// The 5-hour usage window (nil when unknown or turned off).
    @Published var usage: UsageReading?
    /// The pip arc's current choreography frame.
    @Published var pips: PipsFrame = .empty
    /// The session whose pip the pointer is on.
    @Published var hoveredPip: String?
    /// How far the pip arc is turned around the orb so the pips stay on screen (view degrees; 90 = down).
    @Published var pipAround: Double = 90
    /// Quiet mode: the pips step aside with the orb shrunk to a dot.
    @Published var quiet = false
    /// Permission prompts whose hooks are waiting on a click in the bubble, oldest first.
    @Published var approvals: [ApprovalRequest] = []
    /// Sends an Allow or Deny click to the hook that asked.
    var decide: ((ApprovalRequest, ApprovalBehavior) -> Void)?
    /// Sends a question's answers (question text → the label picked) to the hook that asked.
    var answer: ((ApprovalRequest, [String: String]) -> Void)?
    /// Per session, what talking to it is up to (listening, sending, sent): its row shows it.
    @Published var talk: [String: TalkState] = [:]
    /// The mic on a session's row: start listening, or stop and send.
    var toggleTalk: ((Session) -> Void)?
    /// Files, images or text dropped on a session's row; false when there's nothing it can take.
    var dropOn: ((Session, [NSItemProvider]) -> Bool)?

    /// The prompt `session` is waiting on, while it still needs you (answered in the terminal, it moves on).
    func approval(for session: Session) -> ApprovalRequest? {
        guard session.state == .needs else { return nil }
        return approvals.first { $0.session == session.id }
    }

    /// The one request shown in full (the newest still waiting); any others show as a small Deny | Allow pill.
    var expandedApproval: ApprovalRequest? {
        approvals.reversed().first { r in byID[r.session].map { approval(for: $0)?.id == r.id } ?? false }
    }

    /// The island's needs-you card's approval card width (the card less the orb's column and the right margin).
    var needsCardWidth: CGFloat { IslandLayout.size(mode: .needs(""), dock: .top, rest: .live, pips: 0, rows: 0,
                                                    width: islandWidth).width - (22 + IslandLayout.orbSize) - 20 }
    /// The island's session rows' width (the hover panel less its padding).
    var islandRowWidth: CGFloat { IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 0, rows: 0,
                                                    width: islandWidth).width - 16 }
    /// The island's Width setting (IslandModel.width mirrors it for the island's own views).
    var islandWidth: CGFloat = 1

    /// The approval card's height the island needs in `mode` (see IslandLayout.size), 0 for none.
    func islandApprovalHeight(_ mode: IslandMode) -> CGFloat {
        func height(_ r: ApprovalRequest, _ width: CGFloat) -> CGFloat { CGFloat(ApprovalCardLayout.height(r, width: Double(width))) }
        switch mode {
        case let .needs(id):
            guard let s = byID[id], let r = approval(for: s) else { return 0 }
            return height(r, needsCardWidth)
        case .hover:
            guard let r = expandedApproval, sorted.prefix(IslandLayout.maxRows).contains(where: { $0.id == r.session }) else { return 0 }
            return height(r, SessionRow.cardWidth(row: islandRowWidth))
        default:
            return 0
        }
    }
}
