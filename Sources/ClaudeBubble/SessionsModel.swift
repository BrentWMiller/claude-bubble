import AppKit
import ClaudeBubbleCore
import Combine

/// Live sessions, plus the current palette and its mini-orb snapshots, shared by the pips and the hover list.
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var palette: OrbPalette = .agentsView
    @Published var snapshots: [BubbleState: NSImage] = [:]
    /// Mirrors the orb's appear/vanish so the pips pop in and out with it.
    @Published var present = false
    /// Today's working time and session count, refreshed while the list is open.
    @Published var today: DailyActivity.Summary?
}
