import AppKit
import ClaudeBubbleCore

// `ClaudeBubble --export-site <file>`: what the website shows of the app (its story, colours, motions, toasts and
// island sizes) as JSON, so the site stays in step with the app.
if let i = CommandLine.arguments.firstIndex(of: "--export-site"), i + 1 < CommandLine.arguments.count {
    // The bundle's version, or (run from the package with `swift run`) the one in Resources/Info.plist.
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        ?? NSDictionary(contentsOfFile: "Resources/Info.plist")?["CFBundleShortVersionString"] as? String
        ?? "dev"
    do {
        try SiteExport.json(version: version).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
        exit(1)
    }
}

// Settings saved under the app's old bundle ID come along once, before anything reads them. (Not when run
// unbundled, where the defaults domain isn't the bundle ID.)
if let id = Bundle.main.bundleIdentifier { DefaultsMigration.migrate(to: id, in: .standard) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
