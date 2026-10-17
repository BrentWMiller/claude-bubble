import AppKit
import ClaudeBubbleCore
import CryptoKit
import Foundation

/// Keeps the app current from its GitHub releases: checks about once a day (or when asked), and installs a new
/// version in place after checking it: the download matches the release's published SHA-256, it's our app at the
/// version expected, and its code signature is intact. Nothing is replaced unless every check passes.
final class Updater: ObservableObject {
    static let latestURL = URL(string: "https://api.github.com/repos/BrentWMiller/claude-bubble/releases/latest")!

    /// A newer release worth offering (nil when up to date, or the user skipped it).
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var installing = false

    private let defaults = UserDefaults.standard
    private enum Key {
        static let auto = "checkForUpdates", skipped = "skippedVersion", lastCheck = "lastUpdateCheck"
    }
    private var timer: Timer?
    /// Called on the main thread when a new version turns up (not on a manual check, which reports itself).
    var onFound: ((ReleaseInfo) -> Void)?

    var current: AppVersion? {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    var checksAutomatically: Bool {
        get { defaults.object(forKey: Key.auto) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.auto)
            objectWillChange.send()
        }
    }

    /// Checks shortly after launch if a day has passed, then hourly looks whether another day has.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard checksAutomatically,
              UpdatePolicy.due(lastCheck: defaults.object(forKey: Key.lastCheck) as? Date, now: Date()) else { return }
        check { _ in }
    }

    enum CheckResult { case newer(ReleaseInfo), upToDate, failed(String) }

    /// Asks GitHub for the latest release. `done` runs on the main thread.
    func check(manual: Bool = false, done: @escaping (CheckResult) -> Void) {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeBubble/\(current?.description ?? "0")", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.defaults.set(Date(), forKey: Key.lastCheck)
                if let error { return done(.failed(error.localizedDescription)) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200, let data else { return done(.failed("GitHub answered with HTTP \(status).")) }
                guard let release = ReleaseInfo.parse(data) else {
                    return done(.failed("The latest release on GitHub doesn't include an app download to install."))
                }
                guard let current = self.current else { return done(.failed("This build has no version number.")) }
                // A manual check offers even a version the user skipped before.
                let skipped = manual ? nil : (self.defaults.string(forKey: Key.skipped)).flatMap(AppVersion.init)
                guard UpdatePolicy.offer(latest: release.version, current: current, skipped: skipped) else {
                    if release.version <= current { self.available = nil }
                    return done(.upToDate)
                }
                let isNew = self.available != release
                self.available = release
                if isNew, !manual { self.onFound?(release) }
                done(.newer(release))
            }
        }.resume()
    }

    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version.description, forKey: Key.skipped)
        available = nil
    }

    enum InstallError: LocalizedError {
        case notWritable(URL), download(String), checksum, notOurApp(String), signature

        var errorDescription: String? {
            switch self {
            case .notWritable(let url): "Claude Bubble can't replace itself in \(url.deletingLastPathComponent().path)."
            case .download(let why): "The download failed: \(why)"
            case .checksum: "The download doesn't match the release's published checksum."
            case .notOurApp(let why): "The download isn't the expected app (\(why))."
            case .signature: "The downloaded app's code signature isn't valid."
            }
        }
    }

    /// Downloads, checks and swaps in `release`, then relaunches into it. `failed` runs on the main thread if anything
    /// goes wrong, with nothing replaced.
    func install(_ release: ReleaseInfo, failed: @escaping (Error) -> Void) {
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path), FileManager.default.isWritableFile(atPath: app.path) else {
            return failed(InstallError.notWritable(app))
        }
        installing = true
        URLSession.shared.downloadTask(with: release.zip) { [weak self] file, response, error in
            let result: Result<URL, Error> = Result {
                guard let file, error == nil, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw InstallError.download(error?.localizedDescription ?? "no file")
                }
                return try Self.prepare(zip: file, for: release)
            }
            DispatchQueue.main.async {
                self?.installing = false
                switch result {
                case .failure(let error): failed(error)
                case .success(let newApp): Self.swapAndRelaunch(newApp, replacing: app)
                }
            }
        }.resume()
    }

    /// Checks the zip and unpacks it beside nothing important (a temp folder); returns the new app.
    private static func prepare(zip: URL, for release: ReleaseInfo) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw InstallError.checksum }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeBubbleUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else { throw InstallError.notOurApp("couldn't unzip") }
        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw InstallError.notOurApp("no app inside") }

        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw InstallError.notOurApp("a different bundle ID")
        }
        guard (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) == release.version else {
            throw InstallError.notOurApp("not version \(release.version)")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) else { throw InstallError.signature }
        return newApp
    }

    /// Quits, and a small shell waits for this process to end, moves the new app into place (putting the old one
    /// back if that fails), and opens it.
    private static func swapAndRelaunch(_ newApp: URL, replacing app: URL) {
        let backup = app.deletingLastPathComponent().appendingPathComponent(".Claude Bubble.app.old-\(ProcessInfo.processInfo.processIdentifier)")
        let script = """
        while /bin/kill -0 "$PID" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/mv "$APP" "$BAK" || exit 1
        if /bin/mv "$NEW" "$APP"; then /bin/rm -rf "$BAK"; else /bin/mv "$BAK" "$APP"; fi
        /usr/bin/open "$APP"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["PID": String(ProcessInfo.processInfo.processIdentifier), "APP": app.path,
                         "NEW": newApp.path, "BAK": backup.path]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
