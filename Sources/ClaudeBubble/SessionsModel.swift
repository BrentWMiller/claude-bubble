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

    /// The prompt `session` is waiting on, while it still needs you (answered in the terminal, it moves on).
    func approval(for session: Session) -> ApprovalRequest? {
        guard session.state == .needs else { return nil }
        return approvals.first { $0.session == session.id }
    }
}
