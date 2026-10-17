import AppKit
import ClaudeBubbleCore

// Settings saved under the app's old bundle ID come along once, before anything reads them. (Not when run
// unbundled, where the defaults domain isn't the bundle ID.)
if let id = Bundle.main.bundleIdentifier { DefaultsMigration.migrate(to: id, in: .standard) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
