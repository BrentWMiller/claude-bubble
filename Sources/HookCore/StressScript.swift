import Foundation

/// One step of a stress-test agent, as Claude Code would report it to the hook.
public enum StressEvent: Equatable {
    case sessionStart
    case prompt
    /// A tool call starting, from the main agent or (`agent`) one of its subagents.
    case toolStart(id: String, tool: String, agent: String?)
    case toolEnd(id: String, tool: String, failed: Bool, agent: String?)
    case subagentStart(String)
    case subagentStop(String)
    /// The running main-agent tool call stops to ask for permission.
    case permission
    case stop
}

/// A fake Claude Code session for the stress test: a loop of prompts, tool calls (some failing, some asking for
/// permission), subagents with their own tool calls, and stops, at whatever pace it's asked for the next event.
public struct StressAgent {
    public let sessionID: String
    public let cwd: String
    public let maxSubagents: Int
    private var started = false
    private var working = false
    private var mainTool: (id: String, tool: String)?
    private var subagents: [String] = []
    private var subagentTools: [(id: String, tool: String, agent: String)] = []
    private var serial = 0

    static let tools = ["Read", "Grep", "Edit", "Bash", "WebFetch", "Glob", "Write", "mcp__github__get_issue"]

    public init(sessionID: String, cwd: String, maxSubagents: Int) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.maxSubagents = max(0, maxSubagents)
    }

    public mutating func next(using rng: inout some RandomNumberGenerator) -> StressEvent {
        if !started { started = true; return .sessionStart }
        if !working { working = true; return .prompt }
        let roll = Double.random(in: 0..<1, using: &rng)
        // Finish what's running before anything else on that agent.
        if let open = mainTool {
            if roll < 0.04 { return .permission }
            mainTool = nil
            return .toolEnd(id: open.id, tool: open.tool, failed: roll > 0.92, agent: nil)
        }
        if !subagentTools.isEmpty, roll < 0.5 {
            let open = subagentTools.removeFirst()
            return .toolEnd(id: open.id, tool: open.tool, failed: roll < 0.03, agent: open.agent)
        }
        if subagents.count < maxSubagents, roll < 0.08 {
            serial += 1
            let id = "agent-\(serial)"
            subagents.append(id)
            return .subagentStart(id)
        }
        if let agent = subagents.randomElement(using: &rng), roll < 0.4 {
            if subagentTools.contains(where: { $0.agent == agent }) || roll < 0.1 {
                // That subagent finishes (its running tool call with it).
                subagentTools.removeAll { $0.agent == agent }
                subagents.removeAll { $0 == agent }
                return .subagentStop(agent)
            }
            serial += 1
            let call = (id: "toolu_\(serial)", tool: Self.tools.randomElement(using: &rng)!, agent: agent)
            subagentTools.append(call)
            return .toolStart(id: call.id, tool: call.tool, agent: agent)
        }
        if roll > 0.95, subagents.isEmpty {
            working = false
            return .stop
        }
        serial += 1
        let call = (id: "toolu_\(serial)", tool: Self.tools.randomElement(using: &rng)!)
        mainTool = call
        return .toolStart(id: call.id, tool: call.tool, agent: nil)
    }

    /// The hook input Claude Code would send for `event`.
    public func payload(for event: StressEvent) -> [String: Any] {
        var data: [String: Any] = ["session_id": sessionID, "cwd": cwd]
        func tool(_ name: String, _ id: String, _ agent: String?) {
            data["tool_name"] = name
            data["tool_use_id"] = id
            data["tool_input"] = name == "Bash" ? ["description": "Run the test suite", "command": "swift test"]
                : ["file_path": "\(cwd)/Sources/File\(id.count % 9).swift"]
            if let agent { data["agent_id"] = agent }
        }
        switch event {
        case .sessionStart:
            data["hook_event_name"] = "SessionStart"
            data["source"] = "startup"
        case .prompt:
            data["hook_event_name"] = "UserPromptSubmit"
            data["prompt"] = "Keep going"
        case let .toolStart(id, name, agent):
            data["hook_event_name"] = "PreToolUse"
            tool(name, id, agent)
        case let .toolEnd(id, name, failed, agent):
            data["hook_event_name"] = failed ? "PostToolUseFailure" : "PostToolUse"
            tool(name, id, agent)
        case .subagentStart(let agent):
            data["hook_event_name"] = "SubagentStart"
            data["agent_id"] = agent
            data["agent_type"] = "general-purpose"
        case .subagentStop(let agent):
            data["hook_event_name"] = "SubagentStop"
            data["agent_id"] = agent
        case .permission:
            data["hook_event_name"] = "Notification"
            data["notification_type"] = "permission_prompt"
            data["message"] = "Claude needs your permission to use Bash"
        case .stop:
            data["hook_event_name"] = "Stop"
        }
        return data
    }
}

/// A small fast generator with a fixed seed, so a stress run (and its test) repeats exactly.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
