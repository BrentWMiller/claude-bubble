import Accelerate
import AppKit
import AVFoundation
import ClaudeBubbleCore
import HookCore
import Speech
import UniformTypeIdentifiers

/// Talking to a session from its row: what the row shows while it listens and sends.
enum TalkState: Equatable {
    /// Listening, with what it's heard so far.
    case listening(String)
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

    private(set) var states: [String: TalkState] = [:] {
        didSet { onChange?(states) }
    }
    private let dictation = Dictation()
    private var listening: Session?
    private let queue = DispatchQueue(label: "com.claudebubble.talk")

    init() {
        dictation.onHeard = { [weak self] text in
            guard let self, let s = self.listening else { return }
            self.states[s.id] = .listening(text)
        }
        dictation.onLevels = { [weak self] levels in
            guard self?.listening != nil else { return }
            self?.onVoice?(levels)
        }
        dictation.onFinished = { [weak self] text, error in
            guard let self, let s = self.listening else { return }
            self.listening = nil
            self.onVoice?(nil)
            if let message = SessionInbox.spoken(text) {
                self.send(message, to: s)
            } else {
                self.show(error.map(TalkState.failed), for: s)
            }
        }
        queue.async { SessionInbox.pruneDrops() }
    }

    /// The mic on `session`'s row: starts listening, or, while it listens, stops and sends what it heard.
    func toggle(_ session: Session) {
        if let current = listening {
            dictation.finish()
            if current.id == session.id { return }
        }
        guard SessionInbox.peer(sessionId: session.id, pid: session.pid) != nil else {
            show(.failed("Can't reach this session"), for: session)
            return
        }
        listening = session
        states[session.id] = .listening("")
        onVoice?(VoiceLevels(listening: true))
        dictation.start()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
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

/// On-device dictation: hears until it's told to finish, or the speaker goes quiet for a moment after talking.
final class Dictation {
    /// What it's heard so far (main thread).
    var onHeard: ((String) -> Void)?
    /// How loud the mic is, about 47 times a second (main thread).
    var onLevels: ((VoiceLevels) -> Void)?
    /// The final words, and why it stopped early if it failed (main thread). Called once per `start`.
    var onFinished: ((String, String?) -> Void)?

    /// How long a pause after some words ends it.
    static let pause: TimeInterval = 2.2

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = ""
    private var quiet: DispatchWorkItem?
    private var running = false
    private let meter = VoiceMeter()

    func start() {
        heard = ""
        running = true
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { return self.end("Speech recognition is off for Claude Bubble") }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        guard granted else { return self.end("The microphone is off for Claude Bubble") }
                        self.listen()
                    }
                }
            }
        }
    }

    /// Stops listening and reports what it heard.
    func finish() { end(nil) }

    private func listen() {
        guard running else { return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return end("Dictation isn't available") }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return end("No microphone") }
        let meter = meter, rate = Float(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let levels = meter.measure(samples, count: Int(buffer.frameLength), sampleRate: rate)
            DispatchQueue.main.async { self?.onLevels?(levels) }
        }
        self.request = request
        engine.prepare()
        do { try engine.start() } catch { return end("Couldn't start the microphone") }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    self.onHeard?(self.heard)
                    self.waitForPause()
                    if result.isFinal { self.end(nil) }
                } else if error != nil {
                    self.end(nil)
                }
            }
        }
    }

    private func waitForPause() {
        quiet?.cancel()
        guard !heard.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.end(nil) }
        quiet = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pause, execute: work)
    }

    private func end(_ error: String?) {
        guard running else { return }
        running = false
        quiet?.cancel()
        if engine.isRunning { engine.stop() }
        if request != nil { engine.inputNode.removeTap(onBus: 0) }   // tapped, even if the engine never started
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onFinished?(heard, error)
    }
}

/// The mic's loudness and bands, measured like the design's Web Audio analyser (512-point FFT, decibels from -100 to
/// -30 mapped to 0…1, the same three bands and gains), so the orb moves as it does there.
final class VoiceMeter {
    private static let size = 512
    private let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))
    private var window = [Float](repeating: 0, count: VoiceMeter.size)

    init() { vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_NORM)) }
    deinit { if let setup { vDSP_destroy_fftsetup(setup) } }

    /// Called on the audio thread, one buffer at a time.
    func measure(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Float) -> VoiceLevels {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        let n = Self.size
        guard let setup, count >= n else { return VoiceLevels(level: min(1, rms * 5), listening: true) }
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
        func band(_ lo: Float, _ hi: Float) -> Float {
            let a = max(1, Int(lo / hz)), b = min(n / 2, max(a + 1, Int(hi / hz)))
            var sum: Float = 0
            for k in a..<b {
                let db = 10 * log10f(max(power[k], 1e-12)) - 20 * log10f(Float(n))   // zrip's scale, to the analyser's
                sum += min(max((db + 100) / 70, 0), 1)
            }
            return sum / Float(b - a)
        }
        return VoiceLevels(level: min(1, rms * 5), low: min(1, band(94, 750) * 1.4), mid: min(1, band(750, 3750) * 1.8),
                           high: min(1, band(3750, 11250) * 2.5), listening: true)
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
