import AppKit
import ClaudeBubbleCore

// Settings saved under the app's old bundle ID come along once, before anything reads them.
DefaultsMigration.migrate(to: Bundle.main.bundleIdentifier ?? "dev.claudebubble.app", in: .standard)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
