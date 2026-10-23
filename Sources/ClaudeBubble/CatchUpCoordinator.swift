import AppKit
import ClaudeBubbleCore
import Combine
import CoreGraphics

/// Notices you leaving and coming back (no input for the Away after time, or the screen locked or asleep), and on
/// your return puts what changed meanwhile on `SessionsModel.catchUp`: plain lines at once, Claude's when they're
/// written (if that's on). Transcripts are read, and Claude run, off the main thread.
final class CatchUpCoordinator {
    private let model: SessionsModel
    private let settings: SettingsModel
    private let summarizer = CatchUpSummarizer()
    private let io = DispatchQueue(label: "com.claudebubble.catchup.io", qos: .utility)
    private var tracker = AwayTracker()
    private var timer: Timer?
    private var sessions: [Session] = []
    /// Where each session stood when you first left (kept while a catch-up is unseen, so the next one adds on).
    private var marks: [String: SessionMark]?
    private var locked = false
    private var asleep = false
    /// Claude's lines already written, by session id, with the transcript size they were written from.
    private var written: [String: (size: UInt64, line: String, at: Date)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var subs: Set<AnyCancellable> = []

    init(model: SessionsModel, settings: SettingsModel) {
        self.model = model
        self.settings = settings
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.check()
        })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.check()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                                 (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = sleeping
                self?.check()
            })
        }
        settings.$prefs.map { ($0.catchUp, $0.catchUpSummaries) }.removeDuplicates(by: ==)
            .sink { [weak self] on, summaries in self?.apply(on: on, summaries: summaries) }
            .store(in: &subs)
        // Seen and closed: the next absence starts afresh.
        model.$catchUp.sink { [weak self] catchUp in
            guard catchUp == nil, let self else { return }
            self.tracker.keepsLeaveTime = false
        }
        .store(in: &subs)
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// The live sessions, as the app syncs them (main thread).
    func sessionsChanged(_ sessions: [Session]) { self.sessions = sessions }

    private func apply(on: Bool, summaries: Bool) {
        model.catchUpSummaries = summaries
        timer?.invalidate()
        timer = nil
        guard on else {
            model.catchUpOpen = false
            model.catchUp = nil
            marks = nil
            return
        }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        guard timer != nil else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let threshold = TimeInterval(settings.prefs.awayMinutes * 60)
        switch tracker.update(idle: idle, threshold: threshold, inactive: locked || asleep, now: Date()) {
        case .left?: left()
        case let .back(leftAt)?: back(leftAt: leftAt)
        case nil: break
        }
    }

    private func left() {
        guard model.catchUp == nil || model.catchUp?.seen == true else { return }   // unseen: keep the first marks
        let now = sessions
        io.async { [weak self] in
            let offsets = Dictionary(now.compactMap { s in s.transcriptPath.map { (s.id, Self.size($0)) } }, uniquingKeysWith: { a, _ in a })
            DispatchQueue.main.async { self?.marks = AwayCatchUp.marks(now, offsets: offsets) }
        }
    }

    private func back(leftAt: Date) {
        guard let marks else { return }
        build(AwayCatchUp.changed(sessions, since: marks, leftAt: leftAt), marks: marks, leftAt: leftAt)
    }

    /// On demand (the menu's Catch Up): every live session from its latest stretch, unless one's already waiting.
    func catchUpNow() {
        guard settings.prefs.catchUp, model.catchUp == nil || model.catchUp?.seen == true else { return }
        build(sessions, marks: [:], leftAt: tracker.leftAt ?? Date())
    }

    private func build(_ changed: [Session], marks: [String: SessionMark], leftAt: Date) {
        guard !changed.isEmpty else { return }
        let summaries = settings.prefs.catchUpSummaries
        io.async { [weak self] in
            let read = changed.map { s -> (Session, [TranscriptTurn], UInt64) in
                guard let path = s.transcriptPath else { return (s, [], 0) }
                let size = Self.size(path)
                return (s, Self.turns(path, from: TranscriptText.readStart(offset: marks[s.id]?.transcriptOffset ?? 0, fileSize: size), to: size), size)
            }
            DispatchQueue.main.async { self?.show(read, leftAt: leftAt, summaries: summaries) }
        }
    }

    private func show(_ read: [(Session, [TranscriptTurn], UInt64)], leftAt: Date, summaries: Bool) {
        var items: [AwayItem] = []
        var toWrite: [(String, String, UInt64, String)] = []   // session id, input, size, fallback
        for (s, turns, size) in read {
            let plain = TranscriptText.plainLine(turns) ?? (s.detail.isEmpty ? nil : s.detail)
            if summaries, !turns.isEmpty {
                if let done = written[s.id], done.size == size {
                    items.append(AwayItem(sessionID: s.id, line: .written(done.line, at: done.at)))
                } else {
                    items.append(AwayItem(sessionID: s.id, line: .pending(plain: plain)))
                    toWrite.append((s.id, TranscriptText.summaryInput(turns), size, plain ?? ""))
                }
            } else {
                items.append(AwayItem(sessionID: s.id, line: .plain(plain ?? "")))
            }
        }
        let fresh = AwayCatchUp(leftAt: leftAt, items: items, seen: false)
        if let unseen = model.catchUp, !unseen.seen { model.catchUp = unseen.merging(fresh) } else { model.catchUp = fresh }
        model.catchUpOpen = false
        tracker.keepsLeaveTime = true
        for (id, input, size, fallback) in toWrite {
            summarizer.summarize(input) { [weak self] line in
                guard let self, var catchUp = self.model.catchUp,
                      let i = catchUp.items.firstIndex(where: { $0.sessionID == id }) else { return }
                if let line {
                    let at = Date()
                    self.written[id] = (size, line, at)
                    catchUp.items[i].line = .written(line, at: at)
                } else {
                    catchUp.items[i].line = .plain(fallback)
                }
                self.model.catchUp = catchUp
            }
        }
    }

    private static func size(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func turns(_ path: String, from start: UInt64, to end: UInt64) -> [TranscriptTurn] {
        guard end > start, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(end - start)) else { return [] }
        return TranscriptText.turns(fromJSONL: data)
    }
}
