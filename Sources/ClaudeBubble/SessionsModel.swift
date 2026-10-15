import AppKit
import ClaudeBubbleCore
import Combine

/// Live sessions, plus the current palette and its mini-orb snapshots, shared by the pips and the hover list.
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var palette: OrbPalette = .agentsView
    @Published var snapshots: [BubbleState: NSImage] = [:]
}
