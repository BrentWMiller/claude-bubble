import Darwin
import Foundation

/// Approving or denying a Claude Code permission prompt from the bubble.
///
/// On a PermissionRequest the hook connects to the app's Unix socket, sends an `ApprovalRequest` and waits; the app
/// answers with an `ApprovalReply` only when the user clicks Allow or Deny. The terminal's own prompt shows all the
/// while, and whichever answers first wins. Nothing is ever read from a file, so nothing can be forged by writing
/// one: the decision only comes back over the connection the hook itself opened to the app.
public struct ApprovalRequest: Codable, Equatable, Sendable {
    public let id: String
    public let session: String
    public let tool: String
    /// What's being approved, in full: the command, the file, the URL, or the tool's input.
    public let detail: String
    public let cwd: String

    public init(id: String, session: String, tool: String, detail: String, cwd: String) {
        self.id = id
        self.session = session
        self.tool = tool
        self.detail = detail
        self.cwd = cwd
    }

    /// The request for a PermissionRequest hook event, or nil for any other event.
    public static func make(_ input: [String: Any], id: String) -> ApprovalRequest? {
        guard input["hook_event_name"] as? String == "PermissionRequest",
              let session = HookRecorder.sessionID(input), let tool = input["tool_name"] as? String else { return nil }
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        return ApprovalRequest(id: id, session: session, tool: tool, detail: Approval.detail(tool: tool, input: toolInput),
                               cwd: input["cwd"] as? String ?? "")
    }
}

public enum ApprovalBehavior: String, Codable, Sendable { case allow, deny }

public struct ApprovalReply: Codable, Equatable, Sendable {
    public let id: String
    public let behavior: ApprovalBehavior

    public init(id: String, behavior: ApprovalBehavior) {
        self.id = id
        self.behavior = behavior
    }
}

public enum Approval {
    public static let socketName = "approve.sock"
    /// How long the hook waits for a click: just under the 600s timeout Claude Code gives it.
    public static let wait: TimeInterval = 590
    /// The longest detail sent (a huge heredoc or file write stays readable, and the message small).
    public static let maxDetail = 4000

    /// What the user is approving, in full: the command for Bash, the path for file tools, the URL for fetches,
    /// else the tool's input as JSON.
    public static func detail(tool: String, input: [String: Any]) -> String {
        let keys = ["command", "file_path", "notebook_path", "url", "path", "pattern", "query"]
        let text: String
        if let key = keys.first(where: { input[$0] is String }), let value = input[key] as? String {
            text = value
        } else if JSONSerialization.isValidJSONObject(input),
                  let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        return text.count > maxDetail ? String(text.prefix(maxDetail)) + "…" : text
    }

    /// The hook's stdout for a decision.
    public static func output(_ behavior: ApprovalBehavior) -> Data {
        var decision: [String: Any] = ["behavior": behavior.rawValue]
        if behavior == .deny { decision["message"] = "Denied from Claude Bubble." }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
    }

    /// One message: its JSON on a single line.
    public static func line<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The hook keeps waiting only while its session still needs the user. Answering in the terminal moves the
    /// session on (the tool runs, or Claude stops), and its record stops saying "needs".
    public static func stillWaiting(record: [String: Any]?) -> Bool {
        record?["state"] as? String == "needs"
    }
}

/// Unix domain sockets, for the hook (client) and the app (server).
public enum UnixSocket {
    /// Connects to `path`; nil when nothing's listening (the app isn't running, or approvals are off).
    public static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = address(path), withAddress(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Listens on `path` (replacing a stale socket there), readable and writable by this user only.
    public static func listen(_ path: String) -> Int32? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let oldMask = umask(0o077)
        defer { umask(oldMask) }
        guard var addr = address(path), withAddress(&addr, { bind(fd, $0, $1) }) == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        chmod(path, 0o600)
        return fd
    }

    /// Whether the process at the other end of `fd` runs as this user.
    public static func peerIsSelf(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    /// Writes all of `data`; false if the other end has gone.
    @discardableResult
    public static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Waits up to `deadline` for one line, checking `keepWaiting` every `interval`. Nil when the line never came:
    /// the other end closed, the deadline passed, or `keepWaiting` said stop.
    public static func readLine(_ fd: Int32, deadline: Date, interval: TimeInterval = 0.25,
                                keepWaiting: () -> Bool = { true }) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(interval * 1000))
            if ready < 0 { if errno == EINTR { continue } else { return nil } }
            if ready > 0 {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { return nil }
                buffer.append(contentsOf: chunk[0..<n])
                if let end = buffer.firstIndex(of: 0x0A) { return buffer[buffer.startIndex..<end] }
                if buffer.count > 1 << 20 { return nil }
            } else if !keepWaiting() {
                return nil
            }
        }
        return nil
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func withAddress(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}

extension ApprovalRequest {
    /// Asks the app at `socketPath` and waits for the user's click. Nil means no decision (the terminal's prompt
    /// stands): no app listening, the user answered in the terminal (`stillWaiting` turned false), or time ran out.
    public func ask(socketPath: String, deadline: Date, stillWaiting: () -> Bool) -> ApprovalBehavior? {
        guard let fd = UnixSocket.connect(socketPath) else { return nil }
        defer { close(fd) }
        guard UnixSocket.write(fd, Approval.line(self)),
              let line = UnixSocket.readLine(fd, deadline: deadline, keepWaiting: stillWaiting),
              let reply = try? JSONDecoder().decode(ApprovalReply.self, from: line), reply.id == id else { return nil }
        return reply.behavior
    }
}
