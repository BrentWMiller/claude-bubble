import Foundation

/// Running Claude Code itself (`claude -p`) for catch-up's summaries, on your existing sign-in.
public enum ClaudeCLI {
    /// Haiku, one-shot: no tools, no settings files (so none of your hooks, the bubble's among them, fire and no
    /// session shows up), hooks off, and nothing saved to resume. (`--bare` would skip the sign-in: it takes only an
    /// API key.)
    public static let summaryArguments = ["-p", "--model", "claude-haiku-5-5", "--no-session-persistence",
                                          "--tools", "", "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}"]

    /// Where Claude Code is installed: the app isn't started from a shell, so it has no PATH to look along.
    public static func locate(home: URL, isExecutable: (String) -> Bool) -> String? {
        [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
         home.appendingPathComponent(".claude/local/claude").path].first(where: isExecutable)
    }
}

public enum ProcessRun {
    /// Runs `executable` with `input` on stdin and returns what it printed, trimmed; nil if it couldn't start,
    /// failed, printed nothing, or took longer than `timeout` (then it's stopped). Blocks: call it off the main thread.
    public static func output(executable: String, arguments: [String], input: String, cwd: URL? = nil,
                              timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let cwd { p.currentDirectoryURL = cwd }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        // Writing to a process that already quit mustn't kill us with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        var data = Data()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // Asked to stop, then made to; and not waited on past that (nor for its output, which a child it left
            // running may hold open).
            p.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
            return nil
        }
        guard read.wait(timeout: .now() + 5) == .success else { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
