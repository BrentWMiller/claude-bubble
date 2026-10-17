import Foundation

/// The Claude Code hook's logic: given one hook event and the session's previous record, the session's next record.
/// It records each session's state (working, needs you, idle, error), what it's doing, what the orb's surface shows,
/// and its counters, for the Claude Bubble app to read from `~/.claude-bubble/sessions/<id>.json`.
public enum HookRecorder {
    public struct Environment {
        /// `claude -c` replays old events right after SessionStart; events this soon after it are ignored.
        public var replayWindow: Double
        /// A subagent whose SubagentStop never came (an interrupt) is dropped after this long.
        public var subagentTTL: Double

        public init(replayWindow: Double = 3, subagentTTL: Double = 2700) {
            self.replayWindow = replayWindow
            self.subagentTTL = subagentTTL
        }

        public static func from(_ env: [String: String]) -> Environment {
            Environment(replayWindow: env["CLAUDE_BUBBLE_REPLAY_WINDOW"].flatMap(Double.init) ?? 3,
                        subagentTTL: env["CLAUDE_BUBBLE_SUBAGENT_TTL"].flatMap(Double.init) ?? 2700)
        }
    }

    public enum Outcome {
        case ignore
        case delete
        case write([String: Any])
    }

    /// The session id, if it's safe to use as a file name.
    public static func sessionID(_ data: [String: Any]) -> String? {
        let sid = str(data["session_id"])
        return sid.isEmpty || sid.contains("/") || sid.hasPrefix(".") ? nil : sid
    }

    public static func record(_ data: [String: Any], previous prev: [String: Any], now: Double, pid: Int32,
                              env: Environment) -> Outcome {
        guard sessionID(data) != nil else { return .ignore }
        let event = str(data["hook_event_name"])
        if event == "SessionEnd" { return .delete }

        let ntype = str(data["notification_type"])
        var state: String?
        if event == "Notification" {
            state = ["permission_prompt": "needs", "elicitation_dialog": "needs", "elicitation_url_dialog": "needs",
                     "idle_prompt": "idle"][ntype]
        } else {
            state = ["SessionStart": "idle", "UserPromptSubmit": "working", "PreToolUse": "working",
                     "PostToolUse": "working", "PostToolUseFailure": "working", "PermissionDenied": "working",
                     "PermissionRequest": "needs", "Elicitation": "needs", "ElicitationResult": "working",
                     "Stop": "idle", "StopFailure": "error"][event]
        }
        // Subagent and compaction events only feed the orb's motion; they keep whatever state the session is in.
        let keepsState = ["SubagentStart", "SubagentStop", "PreCompact", "PostCompact"].contains(event)
        if state == nil && !keepsState { return .ignore }
        if keepsState { state = nonEmpty(prev["state"]) ?? "working" }

        // Auto-compact and resume fire SessionStart mid-session: keep the current state and replay window.
        let source = data["source"].map { str($0) } ?? "startup"
        let freshStart = event == "SessionStart" && (source == "startup" || source == "clear")
        if event == "SessionStart" && !freshStart && !prev.isEmpty { state = prev["state"].map { str($0) } ?? state }
        var state_ = state ?? "idle"
        let started = freshStart ? now : num(prev["started_at"], 0)
        // Once the user has prompted, everything after is live, not replay.
        let prompted = event == "UserPromptSubmit" || (truthy(prev["prompted"]) && !freshStart)
        if !prompted && event != "SessionStart" && now - started < env.replayWindow { return .ignore }

        // Permission dialogs still waiting on the user, by tool_use_id. Parallel subagents in the same session keep
        // firing tool events, so "needs" must outlive them until its own tool resolves.
        var pending = Set((prev["pending"] as? [Any] ?? []).map { str($0) })
        // PermissionRequest carries no tool_use_id, but the PreToolUse for the same call does. Oldest first.
        var toolIDs = pairs(prev["tool_ids"])
        if event == "PreToolUse", truthy(data["tool_use_id"]) {
            let key = toolKey(data)
            toolIDs.removeAll { $0[0] == key }
            toolIDs.append([key, str(data["tool_use_id"])])
            if toolIDs.count > 20 { toolIDs.removeFirst(toolIDs.count - 20) }
        }
        var toolID = truthy(data["tool_use_id"]) ? str(data["tool_use_id"]) : ""
        if toolID.isEmpty, event == "PermissionRequest" {
            let key = toolKey(data)
            toolID = toolIDs.last { $0[0] == key }?[1] ?? ""
        }
        if toolID.isEmpty { toolID = "?" }
        if ["UserPromptSubmit", "Stop", "StopFailure"].contains(event) || freshStart || ntype == "idle_prompt" {
            pending.removeAll()
        } else if event == "PermissionRequest" || (state_ == "needs" && event == "Notification" && pending.isEmpty) {
            pending.insert(toolID)
        } else if event == "Elicitation" {
            pending.insert("elicitation")
        } else if event == "ElicitationResult" {
            pending.remove("elicitation")
            pending.remove("?")
        } else if ["PostToolUse", "PostToolUseFailure", "PermissionDenied"].contains(event) {
            pending.remove(toolID)
            pending.remove("?")
        }
        if !pending.isEmpty && state_ == "working" { state_ = "needs" }

        let tool = str(data["tool_name"])
        let tin = data["tool_input"] as? [String: Any] ?? [:]

        let prevDetail = str(prev["detail"])
        var detail: String
        if event == "StopFailure" {
            var err = data["error"]
            if let dict = err as? [String: Any] { err = dict["message"] ?? "" }
            detail = truthy(err) ? clip(str(err)) : "Error"
        } else if state_ == "error" {
            detail = prevDetail.isEmpty ? "Error" : prevDetail
        } else if state_ == "needs" {
            if event == "PermissionRequest" {
                var target = base(first(tin["file_path"], tin["notebook_path"]))
                if target.isEmpty { target = clip(str(tin["command"]), 40) }
                detail = clip(target.isEmpty ? "Approve \(tool)?" : "Approve \(tool) \(target)?")
            } else if event == "Elicitation" || ntype == "elicitation_dialog" || ntype == "elicitation_url_dialog" {
                detail = "Input requested"
            } else {
                detail = prevDetail.hasPrefix("Approve") ? prevDetail : "Needs you"
            }
        } else if state_ == "working" {
            if event == "PreToolUse" {
                if tool == "Bash", truthy(tin["description"]) {
                    detail = clip(str(tin["description"]))
                } else if ["Read", "Grep", "Glob"].contains(tool) {
                    detail = "Reading files"
                } else if ["Edit", "Write", "NotebookEdit"].contains(tool) {
                    let name = base(first(tin["file_path"], tin["notebook_path"]))
                    detail = name.isEmpty ? "Editing files" : clip("Editing \(name)")
                } else if ["WebFetch", "WebSearch"].contains(tool) {
                    detail = "Searching the web"
                } else if ["Task", "Agent"].contains(tool) {
                    detail = "Running subagent"
                } else {
                    detail = tool.isEmpty ? "Working" : clip("Using \(tool)")
                }
            } else if event == "UserPromptSubmit" {
                detail = "Thinking"
            } else {
                detail = prevDetail.isEmpty ? "Working" : prevDetail
            }
        } else {
            detail = prompted ? "Completed" : "Idle"
        }
        // Subagent and compaction events say nothing new about the session: keep its status line.
        if keepsState && !prevDetail.isEmpty { detail = prevDetail }

        // Tool events from inside a subagent don't move the main orb's motion (the main agent is waiting on them).
        let fromSubagent = truthy(data["agent_id"]) && !keepsState
        var activity = nonEmpty(prev["activity"]) ?? "generating"
        // The main agent's tool calls still running ([tool_use_id, motion], oldest first): parallel calls end in any
        // order, and the orb goes back to generating only once none are left.
        let turnOver = freshStart || ["UserPromptSubmit", "Stop", "StopFailure"].contains(event)
        var inFlight = turnOver ? [] : pairs(prev["in_flight"], allowObject: false)
        let useID = str(data["tool_use_id"])
        if freshStart {
            activity = "generating"
        } else if !fromSubagent {
            if event == "UserPromptSubmit" || event == "PostCompact" {
                activity = "generating"
            } else if event == "PreToolUse" {
                activity = motion(for: tool)
                inFlight = Array(inFlight.filter { $0[0] != useID }.suffix(19)) + [[useID, activity]]
            } else if ["PostToolUse", "PostToolUseFailure", "PermissionDenied"].contains(event) {
                if inFlight.contains(where: { $0[0] == useID }) {
                    inFlight.removeAll { $0[0] == useID }
                } else if !inFlight.isEmpty {
                    inFlight.removeLast()
                }
                activity = inFlight.last?[1] ?? "generating"
            } else if event == "PreCompact" {
                activity = "compacting"
            } else if event == "SessionStart" && source == "compact" {
                activity = "generating"
            }
        }
        let activitySince = (prev["activity"] as? String) == activity ? num(prev["activity_since"], now) : now

        func counter(_ name: String) -> Int { freshStart ? 0 : Int(num(prev[name], 0)) }
        let ticks = counter("ticks") + (event == "PostToolUse" ? 1 : 0)
        let fails = counter("fails") + (event == "PostToolUseFailure" ? 1 : 0)
        let skills = counter("skills") + (event == "PreToolUse" && ["Skill", "EnterPlanMode", "ExitPlanMode"].contains(tool) ? 1 : 0)

        // Running subagents ({id: started_at}). Background agents outlive the main turn's Stop, so they aren't
        // cleared then; instead one whose SubagentStop never comes (an interrupt) expires after a while.
        var running: [String: Double] = [:]
        if !freshStart {
            if let list = prev["subagents"] as? [Any] {   // written by an older hook
                for x in list { if let s = x as? String { running[s] = now } }
            } else if let map = prev["subagents"] as? [String: Any] {
                for (k, v) in map { if let n = number(v), now - n < env.subagentTTL { running[k] = n } }
            }
        }
        let agent = str(data["agent_id"])
        if event == "SubagentStart", !agent.isEmpty, running[agent] == nil {
            running[agent] = now
        } else if event == "SubagentStop" {
            running[agent] = nil
        }

        let cwd = truthy(data["cwd"]) ? str(data["cwd"]) : str(prev["cwd"])
        let project = base(cwd).isEmpty ? "session" : base(cwd)
        let stateSince = (prev["state"] as? String) == state_ ? num(prev["state_since"], now) : now
        let transcript = truthy(data["transcript_path"]) ? str(data["transcript_path"]) : str(prev["transcript"])

        return .write([
            "state": state_, "event": event, "cwd": cwd, "updated_at": now, "started_at": started,
            "pending": pending.sorted(), "prompted": prompted, "project": project, "detail": detail,
            "state_since": stateSince, "pid": Int(pid), "tool_ids": toolIDs, "activity": activity,
            "activity_since": activitySince, "ticks": ticks, "fails": fails, "skills": skills, "subagents": running,
            "in_flight": inFlight, "transcript": transcript,
        ])
    }

    /// What the orb's surface shows while working (mirrors Motion.forTool in the app).
    public static func motion(for name: String) -> String {
        if name.hasPrefix("mcp__") { return "mcp" }
        let kinds: [(String, [String])] = [("read", ["Read", "NotebookRead"]), ("search", ["Grep", "Glob", "LSP", "ToolSearch"]),
                                          ("edit", ["Edit", "Write", "MultiEdit", "NotebookEdit"]), ("bash", ["Bash", "PowerShell"]),
                                          ("web", ["WebFetch", "WebSearch"]), ("waiting", ["Task", "Agent"])]
        return kinds.first { $0.1.contains(name) }?.0 ?? "generating"
    }

    /// Identifies a tool call by its name and input (key order doesn't matter), so a PermissionRequest can be matched
    /// to the PreToolUse that carried its tool_use_id.
    public static func toolKey(_ data: [String: Any]) -> String {
        var raw = str(data["tool_name"])
        if let input = data["tool_input"], !(input is NSNull),
           let json = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .fragmentsAllowed]) {
            raw += String(decoding: json, as: UTF8.self)
        } else {
            raw += "null"
        }
        let bytes = Array(raw.utf8)
        return String(format: "%08x%04x", crc32(bytes), bytes.count & 0xffff)
    }

    // MARK: - Python-like helpers (the hook started life in Python; these keep its behaviour)

    /// `str(x)` for JSON values; "" for missing or null.
    static func str(_ v: Any?) -> String {
        switch v {
        case nil, is NSNull: return ""
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
            return n.stringValue
        default: return "\(v!)"
        }
    }

    /// Python truthiness for JSON values.
    static func truthy(_ v: Any?) -> Bool {
        switch v {
        case nil, is NSNull: return false
        case let s as String: return !s.isEmpty
        case let n as NSNumber: return n.doubleValue != 0
        case let a as [Any]: return !a.isEmpty
        case let d as [String: Any]: return !d.isEmpty
        default: return true
        }
    }

    static func nonEmpty(_ v: Any?) -> String? { truthy(v) ? str(v) : nil }
    static func first(_ a: Any?, _ b: Any?) -> Any? { truthy(a) ? a : b }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func num(_ v: Any?, _ fallback: Double) -> Double { number(v) ?? fallback }

    /// Collapses whitespace and cuts to `n` characters with an ellipsis.
    static func clip(_ text: String, _ n: Int = 60) -> String {
        let t = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.count <= n ? t : String(t.prefix(n - 1)) + "\u{2026}"
    }

    static func base(_ p: Any?) -> String {
        guard truthy(p) else { return "" }
        var s = str(p)
        while s.hasSuffix("/") { s.removeLast() }
        return s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    /// `[[a, b], …]` pairs; an object (the older hook's tool_ids) becomes its key/value pairs.
    static func pairs(_ v: Any?, allowObject: Bool = true) -> [[String]] {
        if let list = v as? [Any] {
            return list.compactMap { x in
                guard let p = x as? [Any], p.count == 2 else { return nil }
                return [str(p[0]), str(p[1])]
            }
        }
        if allowObject, let map = v as? [String: Any] { return map.map { [$0.key, str($0.value)] } }
        return []
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
