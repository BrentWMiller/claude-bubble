import Foundation

/// Watches the sessions directory and reports the combined state whenever it changes.
/// The 5s timer catches missed events and lets stale sessions age out.
///
/// Files are read on a background queue, and only the ones that changed are decoded again. A burst of events (every
/// hook write is a new file renamed into place, and many sessions write at once) comes through as one reload a short
/// moment later. `onChange` is called on the main thread.
public final class SessionWatcher {
    private let directory: URL
    private let coalesce: TimeInterval
    private let onChange: (BubbleState, [Session]) -> Void
    private let queue = DispatchQueue(label: "com.claudebubble.sessions", qos: .userInitiated)
    private let cache = SessionStore.LoadCache()
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    // On `queue`.
    private var scheduled = false
    private var last: BubbleState?
    private var lastSessions: [Session]?

    public init(directory: URL, coalesce: TimeInterval = 0.05, onChange: @escaping (BubbleState, [Session]) -> Void) {
        self.directory = directory
        self.coalesce = coalesce
        self.onChange = onChange
    }

    public func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
            src.setEventHandler { [weak self] in self?.schedule() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    public func stop() {
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
    }

    /// Reloads now (well, as soon as the queue gets to it).
    public func refresh() {
        queue.async { [weak self] in self?.reload() }
    }

    /// A reload shortly, unless one is already coming.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + coalesce) { [weak self] in
            self?.scheduled = false
            self?.reload()
        }
    }

    private func reload() {
        let now = Date()
        let sessions = PerfMeter.shared.measure(.load) {
            SessionStore.withJobs(SessionStore.live(SessionStore.load(from: directory, now: now, cache: cache), now: now), cache: cache)
        }
        let state = SessionStore.aggregate(sessions, now: now)
        guard state != last || sessions != lastSessions else { return }
        last = state
        lastSessions = sessions
        DispatchQueue.main.async { [onChange] in onChange(state, sessions) }
    }
}
