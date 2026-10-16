import AppIntents
import Foundation
import Intents

/// The Claude Bubble Focus filter (System Settings → Focus → ‹mode› → Focus filters). macOS runs it when that Focus
/// turns on (with the user's "Quiet mode" switch) and again when it turns off (with the switch unset), so attaching
/// it to Do Not Disturb with "turn on when sharing the screen" also covers screen shares.
struct QuietFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Claude Bubble"
    static var description: IntentDescription? = IntentDescription(
        "Quiet the bubble during this Focus: it shrinks to a dot and holds toasts until the Focus ends, then catches you up.")

    @Parameter(title: "Quiet mode")
    var quiet: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: quiet == true ? "Quiet mode" : "Not quiet")
    }

    func perform() async throws -> some IntentResult {
        let on = quiet == true
        await MainActor.run { QuietController.shared.setFilter(on) }   // the controller lives on the main thread
        return .result()
    }
}

/// Quiet mode is on while any source asks for it: the Focus filter, any Focus (when allowed), or the manual toggle.
/// Used on the main thread only.
final class QuietController {
    static let shared = QuietController()

    /// Called whenever quiet mode turns on or off.
    var onChange: ((Bool) -> Void)?
    private(set) var isQuiet = false
    private var filter = false
    private var anyFocus = false
    var manual = false { didSet { update() } }
    private var focusTimer: Timer?

    func setFilter(_ on: Bool) {
        filter = on
        update()
    }

    /// Follow the system Focus status (polled every 2s), after asking for permission. `completion` reports whether
    /// macOS allowed it.
    func followAnyFocus(_ on: Bool, completion: ((Bool) -> Void)? = nil) {
        focusTimer?.invalidate()
        focusTimer = nil
        guard on else {
            anyFocus = false
            update()
            return
        }
        let center = INFocusStatusCenter.default
        let start = { [weak self] in
            guard let self else { return }
            self.pollFocus()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.pollFocus() }
            RunLoop.main.add(timer, forMode: .common)
            self.focusTimer = timer
        }
        if center.authorizationStatus == .authorized {
            start()
            completion?(true)
            return
        }
        center.requestAuthorization { status in
            DispatchQueue.main.async {
                if status == .authorized { start() }
                completion?(status == .authorized)
            }
        }
    }

    private func pollFocus() {
        anyFocus = INFocusStatusCenter.default.focusStatus.isFocused ?? false
        update()
    }

    private func update() {
        let now = filter || anyFocus || manual
        guard now != isQuiet else { return }
        isQuiet = now
        onChange?(now)
    }
}
