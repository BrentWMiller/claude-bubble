import AVFoundation
import ClaudeBubbleCore

/// Plays pip sounds: each request is synthesised off the main thread, then played on one of a few voices.
final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private let queue = DispatchQueue(label: "claude-bubble.sounds", qos: .userInitiated)
    var enabled = true

    init() {
        for _ in 0..<6 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            voices.append(node)
        }
    }

    func play(_ request: SoundRequest, after delay: TimeInterval = 0) {
        guard enabled else { return }
        let format = format
        queue.async { [weak self] in
            let out = PipSynth.render(request, sampleRate: format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(out.left.count)),
                  let channels = buffer.floatChannelData else { return }
            buffer.frameLength = AVAudioFrameCount(out.left.count)
            out.left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: out.left.count) }
            out.right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: out.right.count) }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.schedule(buffer) }
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard enabled else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("ClaudeBubble: audio engine failed: \(error)"); return }
        }
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.stop()   // a voice is reused only after the others; cut whatever it was still ringing
        voice.scheduleBuffer(buffer, completionHandler: nil)
        voice.play()
    }
}
