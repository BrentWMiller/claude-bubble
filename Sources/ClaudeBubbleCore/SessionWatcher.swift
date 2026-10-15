import Foundation

/// Watches the sessions directory and reports the combined state whenever it changes.
/// The 5s timer catches missed events and lets stale sessions age out.
public final class SessionWatcher {
    private let directory: URL
    private let onChange: (BubbleState, [Session]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var last: BubbleState?
    private var lastSessions: [Session]?

    public init(directory: URL, onChange: @escaping (BubbleState, [Session]) -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    public func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.refresh() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    public func refresh() {
        let now = Date()
        let sessions = SessionStore.live(SessionStore.load(from: directory, now: now), now: now)
        let state = SessionStore.aggregate(sessions, now: now)
        if state != last || sessions != lastSessions {
            last = state
            lastSessions = sessions
            onChange(state, sessions)
        }
    }
}
