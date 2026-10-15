import Foundation

/// Watches the sessions directory and reports the combined state whenever it changes.
/// The 5s timer catches missed events and lets stale sessions age out.
public final class SessionWatcher {
    private let directory: URL
    private let onChange: (BubbleState) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var last: BubbleState?

    public init(directory: URL, onChange: @escaping (BubbleState) -> Void) {
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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        let now = Date()
        let state = SessionStore.aggregate(SessionStore.load(from: directory, now: now), now: now)
        if state != last {
            last = state
            onChange(state)
        }
    }
}
