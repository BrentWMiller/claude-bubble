import AVFoundation
import ClaudeBubbleCore
import Combine
import Speech

/// Dictation that never leaves this Mac: hears until it's told to finish (push to talk: the mic is let go). On
/// macOS 26 and later it uses the system's dictation model (`DictationTranscriber`); otherwise, or until that model
/// is installed, the older recogniser, and only when it can work on this Mac. With neither it says so rather than
/// fall back to Apple's servers.
final class Dictation {
    /// What it's heard so far (main thread).
    var onHeard: ((String) -> Void)?
    /// How loud the mic is, about 47 times a second (main thread).
    var onLevels: ((VoiceLevels) -> Void)?
    /// The final words, and why it stopped early if it failed (main thread). Called once per `start`.
    var onFinished: ((String, String?) -> Void)?

    /// How long, once let go, it waits for the last words to be recognised.
    static let settle: TimeInterval = 1.5

    private let engine = AVAudioEngine()
    private var recognizer: SpeechRecognizing?
    private var heard = ""
    private var settling: DispatchWorkItem?
    private var running = false
    private var tapped = false
    /// Which `start` the callbacks in flight belong to (a slow permission or model check can outlive its run).
    private var run = 0
    private let meter = VoiceMeter()

    /// Words and names to listen for this time (your vocabulary and your sessions').
    private var vocabulary: [String] = []

    func start(vocabulary: [String] = []) {
        self.vocabulary = vocabulary
        heard = ""
        running = true
        run += 1
        let run = run
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                guard self.current(run) else { return }
                guard granted else { return self.end("The microphone is off for Claude Bubble") }
                self.chooseRecognizer(run)
            }
        }
    }

    /// Stops listening, then reports what it heard once the last words are in (or `settle` passes).
    func finish() {
        guard running, settling == nil else { return }
        guard let recognizer else { return end(nil) }   // still getting ready: nothing heard
        stopMic()
        recognizer.finish()
        let work = DispatchWorkItem { [weak self] in self?.end(nil) }
        settling = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private func current(_ run: Int) -> Bool { running && run == self.run }

    private func chooseRecognizer(_ run: Int) {
        guard #available(macOS 26, *) else { return olderRecognizer(run) }
        Task { @MainActor in
            let modern = await AnalyzerRecognizer.make(locale: .current, vocabulary: self.vocabulary, onText: self.texts(run))
            guard self.current(run) else { modern?.cancel(); return }
            if let modern { self.listen(with: modern) } else { self.olderRecognizer(run) }
        }
    }

    private func olderRecognizer(_ run: Int) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard self.current(run) else { return }
                guard status == .authorized else { return self.end("Speech recognition is off for Claude Bubble") }
                guard let older = OnDeviceRecognizer(vocabulary: self.vocabulary, onText: self.texts(run)) else {
                    return self.end(Self.unavailable)
                }
                self.listen(with: older)
            }
        }
    }

    /// Why it can't listen: the system model is still downloading, or this Mac can't recognise the language itself.
    private static var unavailable: String {
        let code = Locale.current.language.languageCode?.identifier ?? ""
        let language = Locale.current.localizedString(forLanguageCode: code) ?? "your language"
        if #available(macOS 26, *), AnalyzerRecognizer.downloading {
            return "Getting dictation for \(language) ready; try again in a minute"
        }
        return "On-device dictation isn't available for \(language) on this Mac"
    }

    private func texts(_ run: Int) -> (String, Bool) -> Void {
        { [weak self] text, final in
            guard let self, self.current(run) else { return }
            self.heard = Self.tidy(text)
            self.onHeard?(text)
            if final { self.end(nil) }
        }
    }

    /// What it heard, with your corrections (Settings → Dictation corrections) applied.
    static func tidy(_ text: String) -> String { DictationFixes.apply(DictationFixesModel.shared.fixes, to: text) }

    private func listen(with recognizer: SpeechRecognizing) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            recognizer.cancel()
            return end("No microphone")
        }
        self.recognizer = recognizer
        let meter = meter, rate = Float(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            recognizer.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let levels = meter.measure(samples, count: Int(buffer.frameLength), sampleRate: rate)
            DispatchQueue.main.async { self?.onLevels?(levels) }
        }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch { return end("Couldn't start the microphone") }
    }

    private func stopMic() {
        if engine.isRunning { engine.stop() }
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }   // even if the engine never started
    }

    private func end(_ error: String?) {
        guard running else { return }
        running = false
        settling?.cancel()
        settling = nil
        stopMic()
        recognizer?.cancel()
        recognizer = nil
        onFinished?(heard, error)
    }
}

/// Turns the mic's audio into words. `onText` (main thread) gets everything heard so far each time it changes, and
/// once more, final, when it's done.
private protocol SpeechRecognizing: AnyObject {
    /// One buffer of the mic's audio (on the audio thread).
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio: finish recognising what's there.
    func finish()
    func cancel()
}

/// The older recogniser (`SFSpeechRecognizer`), only where it runs on this Mac.
private final class OnDeviceRecognizer: SpeechRecognizing {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?

    /// Nil when this Mac can't recognise the language itself.
    init?(vocabulary: [String], onText: @escaping (String, Bool) -> Void) {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            return nil
        }
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = vocabulary
        var last = ""
        task = recognizer.recognitionTask(with: request) { result, error in
            DispatchQueue.main.async {
                if let result {
                    last = result.bestTranscription.formattedString
                    onText(last, result.isFinal)
                } else if error != nil {
                    onText(last, true)
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func finish() { request.endAudio() }
    func cancel() { task?.cancel() }
}

/// The system's dictation model (macOS 26): on this Mac only, punctuated like keyboard dictation.
@available(macOS 26, *)
private final class AnalyzerRecognizer: SpeechRecognizing {
    /// A model download it started is still going.
    static var downloading = false

    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat?
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?

    /// Nil when it can't listen yet: the language isn't supported, or its model isn't installed (the download starts
    /// now, for next time). The dictation model (`DictationTranscriber`) first: given your vocabulary it gets names
    /// right that the newer transcription model (`SpeechTranscriber`, which ignores it) mishears; that one covers the
    /// languages dictation doesn't.
    static func make(locale: Locale, vocabulary: [String], onText: @escaping (String, Bool) -> Void) async -> AnalyzerRecognizer? {
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let t = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
            return await ready(t, named: "DictationTranscriber", vocabulary: vocabulary, onText: onText) {
                texts(t.results) { (String($0.text.characters), $0.isFinal) }
            }
        }
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let t = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            return await ready(t, named: "SpeechTranscriber", vocabulary: vocabulary, onText: onText) {
                texts(t.results) { (String($0.text.characters), $0.isFinal) }
            }
        }
        return nil
    }

    private static func ready(_ module: any SpeechModule, named name: String, vocabulary: [String],
                              onText: @escaping (String, Bool) -> Void,
                              results: @escaping () -> AsyncThrowingStream<(String, Bool), Error>) async -> AnalyzerRecognizer? {
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            if !downloading, let request = try? await AssetInventory.assetInstallationRequest(supporting: [module]) {
                downloading = true
                Task.detached {
                    try? await request.downloadAndInstall()
                    await MainActor.run { downloading = false }
                }
            }
            return nil
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        NSLog("ClaudeBubble: dictation with %@, %d vocabulary words", name, vocabulary.count)
        return AnalyzerRecognizer(module, results: results(), format: format, vocabulary: vocabulary, onText: onText)
    }

    /// A module's results as (text, final), whichever module it is.
    private static func texts<S: AsyncSequence & Sendable>(_ results: S, _ read: @escaping @Sendable (S.Element) -> (String, Bool))
        -> AsyncThrowingStream<(String, Bool), Error> {
        AsyncThrowingStream { out in
            Task {
                do {
                    for try await result in results { out.yield(read(result)) }
                    out.finish()
                } catch {
                    out.finish(throwing: error)
                }
            }
        }
    }

    private init(_ module: any SpeechModule, results: AsyncThrowingStream<(String, Bool), Error>, format: AVAudioFormat?,
                 vocabulary: [String], onText: @escaping (String, Bool) -> Void) {
        self.format = format
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        let context = AnalysisContext()
        context.contextualStrings[.general] = vocabulary
        Task {
            // The words to listen for, before the first audio.
            if !vocabulary.isEmpty { try? await analyzer.setContext(context) }
            try? await analyzer.start(inputSequence: stream)
        }
        Task {
            // Finished stretches stay; the latest, still-changing one is replaced each time.
            var done = "", live = ""
            do {
                for try await (text, final) in results {
                    if final {
                        done = Self.join(done, text)
                        live = ""
                    } else {
                        live = text
                    }
                    let now = Self.join(done, live)
                    await MainActor.run { onText(now, false) }
                }
            } catch {}
            let final = Self.join(done, live)
            await MainActor.run { onText(final, true) }
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b.trimmingCharacters(in: .whitespaces) }
        if b.isEmpty { return a }
        return a.hasSuffix(" ") || b.hasPrefix(" ") ? a + b : a + " " + b
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Into the model's own format (a fresh buffer either way: the mic's is reused once this returns).
        guard let format else { return }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() {
        input.finish()
        Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
        input.finish()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}

/// Your dictation corrections, edited in Settings and kept across restarts (the defaults until you change them).
final class DictationFixesModel: ObservableObject {
    static let shared = DictationFixesModel()
    private static let key = "dictationFixes"

    @Published var fixes: [DictationFix] {
        didSet { (try? JSONEncoder().encode(fixes)).map { UserDefaults.standard.set($0, forKey: Self.key) } }
    }

    private init() {
        fixes = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([DictationFix].self, from: $0) }
            ?? DictationFixes.defaults
    }

    func add() { fixes.append(DictationFix(heard: "", meant: "")) }
    func remove(_ id: UUID) { fixes.removeAll { $0.id == id } }
    func reset() { fixes = DictationFixes.defaults }
}

/// The words and names you add in Settings for dictation to listen for, kept across restarts.
final class DictationVocabularyModel: ObservableObject {
    static let shared = DictationVocabularyModel()
    private static let key = "dictationVocabulary"

    @Published var words: [String] {
        didSet { UserDefaults.standard.set(words, forKey: Self.key) }
    }

    private init() {
        words = UserDefaults.standard.stringArray(forKey: Self.key) ?? DictationVocabulary.defaults
    }
}
