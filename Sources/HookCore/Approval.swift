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
    /// Claude's own reason, when the tool gives one (Bash's description).
    public var reason: String?
    /// For file edits and writes: what changes, to show as a diff.
    public var edits: [ApprovalEdit]?

    public init(id: String, session: String, tool: String, detail: String, cwd: String, reason: String? = nil,
                edits: [ApprovalEdit]? = nil) {
        self.id = id
        self.session = session
        self.tool = tool
        self.detail = detail
        self.cwd = cwd
        self.reason = reason
        self.edits = edits
    }

    /// The request for a PermissionRequest hook event, or nil for any other event.
    /// `readFile` supplies the edited file's text, for a line of context above the change.
    public static func make(_ input: [String: Any], id: String,
                            readFile: (String) -> String? = { _ in nil }) -> ApprovalRequest? {
        guard input["hook_event_name"] as? String == "PermissionRequest",
              let session = HookRecorder.sessionID(input), let tool = input["tool_name"] as? String else { return nil }
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let reason = (toolInput["description"] as? String).map { Approval.capped($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return ApprovalRequest(id: id, session: session, tool: tool, detail: Approval.detail(tool: tool, input: toolInput),
                               cwd: input["cwd"] as? String ?? "", reason: tool == "Bash" ? reason : nil,
                               edits: ApprovalEdit.edits(tool: tool, input: toolInput, readFile: readFile))
    }
}

/// One change to a file: the text replaced and its replacement ("" old for a whole-file write), and the file's
/// line just above it, when it could be found.
public struct ApprovalEdit: Codable, Equatable, Sendable {
    public let old: String
    public let new: String
    public var above: String?

    public init(old: String, new: String, above: String? = nil) {
        self.old = old
        self.new = new
        self.above = above
    }

    static func edits(tool: String, input: [String: Any], readFile: (String) -> String?) -> [ApprovalEdit]? {
        let pairs: [(String, String)]
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String, let new = input["new_string"] as? String else { return nil }
            pairs = [(old, new)]
        case "MultiEdit":
            pairs = (input["edits"] as? [[String: Any]] ?? []).compactMap { e in
                guard let old = e["old_string"] as? String, let new = e["new_string"] as? String else { return nil }
                return (old, new)
            }
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            pairs = [("", content)]
        default:
            return nil
        }
        guard !pairs.isEmpty else { return nil }
        let file = (input["file_path"] as? String).flatMap(readFile)
        return pairs.prefix(8).map { old, new in
            ApprovalEdit(old: Approval.capped(old), new: Approval.capped(new), above: file.flatMap { line(above: old, in: $0) })
        }
    }

    /// The line before the one where `old` starts in `file`.
    static func line(above old: String, in file: String) -> String? {
        guard !old.isEmpty, let range = file.range(of: old) else { return nil }
        let head = file[..<range.lowerBound]
        guard let start = head.lastIndex(of: "\n") else { return nil }   // starts on the file's first line
        let previous = head[..<start]
        let lineStart = previous.lastIndex(of: "\n").map { previous.index(after: $0) } ?? previous.startIndex
        return String(previous[lineStart...])
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
        return capped(text)
    }

    static func capped(_ text: String) -> String {
        text.count > maxDetail ? String(text.prefix(maxDetail)) + "…" : text
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

// MARK: Showing a request

/// The changed lines of an edit, as shown on the approval card: a line of context, then removed, then added lines.
public struct ApprovalDiff: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, removed, added }
    public struct Line: Equatable, Sendable {
        public let kind: Kind
        public let text: String
    }
    /// The lines shown (at most `maxLines`).
    public let lines: [Line]
    /// Lines left out past `maxLines`.
    public let hidden: Int
    public let added: Int
    public let removed: Int

    public static let maxLines = 6

    public init(_ edits: [ApprovalEdit], maxLines: Int = ApprovalDiff.maxLines) {
        var all: [Line] = []
        var added = 0, removed = 0
        for edit in edits {
            let old = edit.old.isEmpty ? [] : edit.old.components(separatedBy: "\n")
            let new = edit.new.isEmpty ? [] : edit.new.components(separatedBy: "\n")
            // Lines the edit keeps at either end aren't changes.
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(old.count, new.count) - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
                suffix += 1
            }
            let gone = old[prefix..<(old.count - suffix)], came = new[prefix..<(new.count - suffix)]
            if prefix > 0 { all.append(Line(kind: .context, text: old[prefix - 1])) }
            else if let above = edit.above { all.append(Line(kind: .context, text: above)) }
            all += gone.map { Line(kind: .removed, text: $0) } + came.map { Line(kind: .added, text: $0) }
            removed += gone.count
            added += came.count
        }
        lines = Array(all.prefix(maxLines))
        hidden = max(0, all.count - maxLines)
        self.added = added
        self.removed = removed
    }
}

extension ApprovalRequest {
    /// What Claude wants, in a few words.
    public var headline: String {
        switch tool {
        case "Bash": return "Wants to run a Bash command"
        case "Edit", "MultiEdit", "NotebookEdit": return "Wants to edit a file"
        case "Write": return "Wants to write a file"
        case "Read": return "Wants to read a file"
        case "WebFetch": return "Wants to fetch a page"
        case "WebSearch": return "Wants to search the web"
        case "Task", "Agent": return "Wants to start an agent"
        default:
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return "Wants to use \(parts[1])'s \(parts[2...].joined(separator: "__"))" }
            return "Wants to use \(tool)"
        }
    }

    /// The Allow button's title.
    public var allowTitle: String { edits == nil ? "Allow" : tool == "Write" ? "Allow write" : "Allow edit" }

    /// The diff for an edit or write.
    public var diff: ApprovalDiff? { edits.map { ApprovalDiff($0) } }

    /// The code block's label: the tool, or the file being changed (relative to the session's folder).
    public var blockLabel: String {
        guard edits != nil else { return tool.hasPrefix("mcp__") ? "MCP" : tool.uppercased() }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return !cwd.isEmpty && detail.hasPrefix(base) ? String(detail.dropFirst(base.count)) : detail
    }
}

/// The approval card's fixed measurements (it's laid out to exactly these, so the island can size itself to fit).
public enum ApprovalCardLayout {
    public static let spacing: Double = 8
    public static let buttonHeight: Double = 30
    public static let blockHeader: Double = 24
    public static let codeLine: Double = 15
    public static let diffLine: Double = 17
    public static let reasonLine: Double = 16
    public static let blockPadding: Double = 14
    public static let moreLine: Double = 16
    /// Average glyph widths, to estimate wrapping: 11pt monospaced code, 12pt reason text.
    public static let codeGlyph: Double = 6.65
    public static let textGlyph: Double = 6.1

    /// Lines `text` takes at `width` with `glyph`-wide characters (wrapping each line), at most `limit`.
    public static func lines(_ text: String, width: Double, glyph: Double, limit: Int) -> Int {
        let columns = max(1, Int(width / glyph))
        let wrapped = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, ($1.count + columns - 1) / columns) }
        return min(limit, max(1, wrapped))
    }

    public static func reasonLines(_ r: ApprovalRequest, width: Double) -> Int {
        r.reason.map { lines($0, width: width, glyph: textGlyph, limit: 2) } ?? 0
    }

    /// The code block's body lines (code), at the block's inner width.
    public static func codeLines(_ r: ApprovalRequest, width: Double) -> Int {
        lines(r.tool == "Bash" ? "$ " + r.detail : r.detail, width: width - 20, glyph: codeGlyph, limit: 3)
    }

    public static func blockHeight(_ r: ApprovalRequest, width: Double) -> Double {
        if let diff = r.diff {
            return blockHeader + Double(max(diff.lines.count, 1)) * diffLine + 8 + (diff.hidden > 0 ? moreLine : 0)
        }
        return blockHeader + Double(codeLines(r, width: width)) * codeLine + blockPadding
    }

    /// The whole card: reason, code block, buttons.
    public static func height(_ r: ApprovalRequest, width: Double) -> Double {
        let reason = reasonLines(r, width: width)
        return (reason > 0 ? Double(reason) * reasonLine + spacing : 0) + blockHeight(r, width: width) + spacing + buttonHeight
    }

    /// The tallest a card gets (two reason lines, a full diff with "more").
    public static var maxHeight: Double {
        2 * reasonLine + spacing + blockHeader + Double(ApprovalDiff.maxLines) * diffLine + 8 + moreLine + spacing + buttonHeight
    }
}
