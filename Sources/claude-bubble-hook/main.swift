import Darwin
import Foundation
import HookCore

// Claude Bubble's Claude Code hook: records the session's state for the app. Claude pipes the hook event's JSON in
// on stdin. Never blocks or fails Claude: it prints nothing and always exits 0.

let env = ProcessInfo.processInfo.environment
let dir = URL(fileURLWithPath: env["CLAUDE_BUBBLE_DIR"] ?? (NSHomeDirectory() + "/.claude-bubble"))
    .appendingPathComponent("sessions")

/// A process's parent and command name, straight from the kernel (no `ps`).
func processInfo(_ pid: pid_t) -> (parent: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return (info.kp_eproc.e_ppid, name)
}

/// Claude runs hooks through a shell; walk past shells to the Claude process that owns this session. Only a confirmed
/// non-shell owner counts: anything else would be a short-lived process the app would see die and drop the session
/// for. 0 means unknown, and the app falls back to staleness.
func owner() -> Int32 {
    if let given = env["CLAUDE_BUBBLE_PID"], !given.isEmpty { return Int32(given) ?? 0 }
    var pid = getppid()
    for _ in 0..<5 {
        guard let p = processInfo(pid) else { return 0 }
        switch p.name {
        case "sh", "bash", "zsh", "dash", "-sh", "-bash", "-zsh": pid = p.parent
        default: return pid
        }
    }
    return 0
}

func run() {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let data = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let sid = HookRecorder.sessionID(data) else { return }
    let path = dir.appendingPathComponent(sid + ".json")
    let previous = (try? Data(contentsOf: path)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    switch HookRecorder.record(data, previous: previous, now: Date().timeIntervalSince1970, pid: owner(),
                               env: .from(env)) {
    case .ignore:
        return
    case .delete:
        try? FileManager.default.removeItem(at: path)
    case .write(let record):
        // isValidJSONObject first: JSONSerialization raises (not throws) on anything it can't encode.
        guard JSONSerialization.isValidJSONObject(record), let out = try? JSONSerialization.data(withJSONObject: record) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write beside it, then rename over it: the app never reads a half-written file.
        let tmp = dir.appendingPathComponent(".tmp-\(getpid())-\(UInt64(Date().timeIntervalSince1970 * 1e9))")
        do {
            try out.write(to: tmp, options: .withoutOverwriting)
            chmod(tmp.path, 0o600)   // what the session is doing and where: private, like the Python hook's
            if rename(tmp.path, path.path) != 0 { try? FileManager.default.removeItem(at: tmp) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

run()
exit(0)
