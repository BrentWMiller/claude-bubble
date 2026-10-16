import AppKit
import ClaudeBubbleCore
import Combine

/// Live sessions, plus the current palette, shared by the pips and the hover list.
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
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
}
