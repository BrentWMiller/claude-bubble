import ClaudeBubbleCore
import Combine

/// Live sessions shared by the pips and the hover list.
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
}
