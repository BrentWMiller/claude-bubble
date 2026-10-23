import ClaudeBubbleCore
import Foundation

/// Writes catch-up's lines with Claude (Haiku, through `claude -p` on your sign-in), three at a time, off the main
/// thread. Anything that goes wrong (no Claude Code, signed out, slow) comes back nil, and the plain line stays.
final class CatchUpSummarizer {
    private let executable: String?
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.claudebubble.catchup.summaries", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 3)

    init(executable: String? = ClaudeCLI.locate(home: FileManager.default.homeDirectoryForCurrentUser,
                                                isExecutable: FileManager.default.isExecutableFile(atPath:)),
         timeout: TimeInterval = 60) {
        self.executable = executable
        self.timeout = timeout
    }

    /// The summary's first line, at most 160 characters (main thread); nil on any failure.
    func summarize(_ input: String, completion: @escaping (String?) -> Void) {
        guard let executable else { return completion(nil) }
        queue.async { [slots, timeout] in
            slots.wait()
            defer { slots.signal() }
            let out = ProcessRun.output(executable: executable, arguments: ClaudeCLI.summaryArguments, input: input,
                                        cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: timeout)
            let line = out?.split(separator: "\n").first.map { String($0.prefix(160)) }
            DispatchQueue.main.async { completion(line) }
        }
    }
}
