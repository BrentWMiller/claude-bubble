import Accelerate
import AppKit
import AVFoundation
import ClaudeBubbleCore
import HookCore
import Speech
import UniformTypeIdentifiers

/// Talking to a session from its row: what the row shows while it listens and sends.
enum TalkState: Equatable {
    /// Listening (the mic held, or the last words still being recognised), since when, and what it's heard so far.
    case listening(since: Date, words: String)
    /// What you said is open to edit before it's sent.
    case drafting
    case sending
    case sent
    case failed(String)
}

/// Says and drops things to sessions through their inboxes (see SessionInbox): dictates on this Mac, sends the
/// words, and turns dropped files, images and text into a message. One session listens at a time.
final class SessionTalk {
    /// Per session, what its row shows; delivered on the main thread.
    var onChange: (([String: TalkState]) -> Void)?
    /// A message reached `session`.
    var onSent: ((Session) -> Void)?
    /// What the orb should hear: your voice while it listens, nil once it stops (main thread).
    var onVoice: ((VoiceLevels?) -> Void)?
    /// Your sessions' and projects' names, for dictation to listen for.
    var sessionNames: (() -> [String])?
    /// Talking to `session` failed, and why (main thread).
    var onFailed: ((Session, String) -> Void)?
    /// You let go of the mic: what it heard, to edit before it goes (send it with `send(_:to:)`).
    var onDraft: ((Session, String, TimeInterval) -> Void)?

    private(set) var states: [String: TalkState] = [:] {
        didSet { onChange?(states) }
    }
    private let dictation = Dictation()
    private var listening: Session?
    private var listeningSince = Date()
    /// When the mic was let go (the draft shows how long you talked, not how long the last words took).
    private var releasedAt: Date?
    private let queue = DispatchQueue(label: "com.claudebubble.talk")

    init() {
        dictation.onHeard = { [weak self] words in
            guard let self, let s = self.listening else { return }
            self.states[s.id] = .listening(since: self.listeningSince, words: words)
        }
        dictation.onLevels = { [weak self] levels in
            guard let s = self?.listening else { return }
            var levels = levels
            levels.look = s.tone.orbState   // the orb wears the session's colours, as its row does
            // Your voice moves it the way the design's "Claude speaking" does (rim wobbling out, ripples running out):
            // stronger than the design's listening look.
            levels.listening = false
            self?.onVoice?(levels)
            VoiceBarsModel.shared.hear(levels.level)
        }
        dictation.onFinished = { [weak self] text, error in
            guard let self, let s = self.listening else { return }
            self.listening = nil
            self.onVoice?(nil)
            VoiceBarsModel.shared.hear(nil)
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty, let onDraft = self.onDraft {
                self.states[s.id] = .drafting
                onDraft(s, words, (self.releasedAt ?? Date()).timeIntervalSince(self.listeningSince))
            } else if let message = SessionInbox.spoken(words) {
                self.send(message, to: s)
            } else {
                self.show(error.map(TalkState.failed), for: s)
            }
        }
        queue.async { SessionInbox.pruneDrops() }
    }

    /// Sends a draft you checked (and maybe edited) to `session`; nil or empty text drops it.
    func send(draft text: String?, to session: Session) {
        if let text, let message = SessionInbox.spoken(text) {
            send(message, to: session)
        } else if states[session.id] == .drafting {
            states[session.id] = nil
        }
    }

    /// Push to talk on `session`'s row: listens while the mic is held, then opens what it heard as a draft.
    func hold(_ session: Session, down: Bool) {
        guard down else {
            if listening?.id == session.id {
                releasedAt = Date()
                dictation.finish()
            }
            return
        }
        if listening != nil { dictation.finish() }
        guard SessionInbox.peer(sessionId: session.id, pid: session.pid) != nil else {
            show(.failed("Can't reach this session"), for: session)
            return
        }
        listening = session
        listeningSince = Date()
        releasedAt = nil
        states[session.id] = .listening(since: listeningSince, words: "")
        onVoice?(VoiceLevels(listening: false, look: session.tone.orbState))
        let settings = DictationVocabularyModel.shared
        dictation.start(vocabulary: DictationVocabulary.words(yours: settings.words,
                                                              sessions: settings.listensForSessions ? sessionNames?() ?? [] : []))
    }

    /// Things dropped on `session`'s row (or on the orb, for its most pressing session).
    func drop(_ providers: [NSItemProvider], on session: Session) -> Bool {
        guard !providers.isEmpty else { return false }
        DropReader.read(providers) { [weak self] files, texts in
            guard let self else { return }
            if let message = SessionInbox.dropped(files: files, texts: texts) {
                self.send(message, to: session)
            } else {
                self.show(.failed("Nothing to send"), for: session)
            }
        }
        return true
    }

    private func send(_ message: String, to session: Session) {
        states[session.id] = .sending
        queue.async { [weak self] in
            let ok = SessionInbox.peer(sessionId: session.id, pid: session.pid).map { InboxSender.send(message, to: $0) } ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.show(ok ? .sent : .failed("Couldn't send"), for: session)
                if ok { self.onSent?(session) }
            }
        }
    }

    /// Shows `state` on the row for a moment, then clears it (nil clears it now).
    private func show(_ state: TalkState?, for session: Session) {
        states[session.id] = state
        guard let state else { return }
        if case let .failed(why) = state { onFailed?(session, why) }
        // "Sent to Claude" just confirms it (design: Session Card); a failure stays long enough to read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (state == .sent ? 1.8 : 3)) { [weak self] in
            if self?.states[session.id] == state { self?.states[session.id] = nil }
        }
    }
}

/// Writes a message to a session's inbox socket. Nothing comes back, so "sent" means the session's socket took it.
enum InboxSender {
    static func send(_ message: String, to peer: InboxPeer) -> Bool {
        guard let fd = UnixSocket.connect(peer.socketPath) else { return false }
        defer { close(fd) }
        return UnixSocket.write(fd, SessionInbox.payload(message, token: peer.token))
    }
}

/// The mic's loudness and bands, measured like the design's Web Audio analyser (512-point FFT, decibels from -100 to
/// -30 mapped to 0…1, the same three bands and gains), so the orb moves as it does there.
final class VoiceMeter {
    private static let size = 512
    private let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: VoiceMeter.size)

    /// The loudest you've been lately (RMS), for the gain: eases down over a few seconds.
    private var peak: Float = 0.02

    init() { vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM)) }
    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    /// Called on the audio thread, one buffer at a time.
    func measure(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> VoiceLevels {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        // Automatic gain, as a browser's mic has (the design's analyser hears that): the raw mic is far quieter, so
        // scale your voice so its recent peaks land where a browser's would (about 0.2 RMS), at most 30×.
        peak = max(rms, peak * 0.995, 0.005)
        let gain = min(max(0.2 / peak, 1), 30)
        let level = min(1, rms * gain * 5)
        let n = Self.size
        guard let setup, count >= n else { return VoiceLevels(level: level, listening: true) }
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        // Bin k of the design's analyser at 48kHz is k × 93.75Hz: lows 1–8, mids 8–40, highs 40–120.
        let hz = sampleRate / Float(n)
        let boost = 20 * log10f(gain)
        // The spectrum the orb draws: 16 bands spaced evenly in pitch, 80Hz to 8kHz, loud bands standing out from
        // the hush between words (squared), with the same gain as the rest.
        var spectrum = SIMD16<Float>(repeating: 0)
        for i in 0..<16 {
            let lo = 80 * powf(100, Float(i) / 16), hi = 80 * powf(100, Float(i + 1) / 16)
            let a = max(1, Int(lo / hz)), b = min(n / 2, max(a + 1, Int(hi / hz)))
            var top: Float = 1e-12
            for k in a..<b { top = max(top, power[k]) }
            let db = 10 * log10f(top) - 20 * log10f(Float(n)) + boost
            let v = min(max((db + 75) / 45, 0), 1)
            spectrum[i] = v * v
        }
        func band(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / hz)), b = min(n / 2, max(a + 1, Int(hi / hz)))
            var sum: Float = 0
            for k in a..<b {
                let db = 10 * log10f(max(power[k], 1e-12)) - 20 * log10f(Float(n)) + boost   // zrip's scale, to the analyser's
                sum += min(max((db + 100) / 70, 0), 1)
            }
            return sum / Float(b - a)
        }
        var levels = VoiceLevels(level: level, low: min(1, band(94, 750) * 1.4), mid: min(1, band(750, 3750) * 1.8),
                                 high: min(1, band(3750, 11250) * 2.5), listening: true)
        levels.spectrum = spectrum
        return levels
    }
}

/// Turns dropped items into what a message can carry: file paths, and text (an image or long text with no file
/// behind it is written to the drops folder first, so it has a path too).
enum DropReader {
    static let types: [UTType] = [.fileURL, .url, .image, .plainText]

    static func read(_ providers: [NSItemProvider], done: @escaping ([URL], [String]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var files: [URL] = [], texts: [String] = []
        func add(file: URL? = nil, text: String? = nil) {
            lock.lock()
            if let file { files.append(file) }
            if let text { texts.append(text) }
            lock.unlock()
        }
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in add(file: url); group.leave() }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    add(file: data.flatMap(png).flatMap { SessionInbox.stage($0, ext: "png") })
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in add(text: url?.absoluteString); group.leave() }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    if let text, text.count > SessionInbox.inlineTextLimit {
                        add(file: SessionInbox.stage(Data(text.utf8), ext: "txt"))
                    } else {
                        add(text: text)
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { done(files, texts) }
    }

    /// The image as PNG, whatever it came as.
    private static func png(_ data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
