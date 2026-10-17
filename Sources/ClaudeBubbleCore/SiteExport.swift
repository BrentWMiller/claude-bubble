import Foundation

extension Motion {
    /// The design's name for this motion's `WORK` mode (what the web orb's `work` attribute takes).
    public var designWork: String {
        switch self {
        case .generating: "wave"
        case .read: "converge"
        case .search: "radar"
        case .edit: "ripple"
        case .bash: "bash"
        case .web: "drift"
        case .mcp: "link"
        case .compacting: "compact"
        case .waiting: "wait"
        }
    }

    /// One word for it ("Reading").
    public var verb: String {
        switch self {
        case .generating: "Thinking"
        case .read: "Reading"
        case .search: "Searching"
        case .edit: "Editing"
        case .bash: "Running"
        case .web: "Fetching"
        case .mcp: "Linking"
        case .compacting: "Compacting"
        case .waiting: "Delegating"
        }
    }

    /// A short phrase for it ("Reading files").
    public var summary: String {
        switch self {
        case .generating: "Thinking"
        case .read: "Reading files"
        case .search: "Searching the codebase"
        case .edit: "Editing files"
        case .bash: "Running a command"
        case .web: "Fetching a web page"
        case .mcp: "Calling an MCP tool"
        case .compacting: "Compacting the conversation"
        case .waiting: "Waiting on subagents"
        }
    }
}

/// What the website needs from the app, so the site shows the app as it is: the scripted session the setup demo
/// plays, the Claude theme's colours in the web orb's format, each motion's work mode and words, the toasts' wording
/// and colours, and the island's sizes. Written by `ClaudeBubble --export-site <file>`.
public enum SiteExport {
    public static func json(version: String) throws -> Data {
        let pal = OrbPalette.originalDesign
        func colors(_ c: StateColors) -> [String: [Double]] {
            let v = { (s: SIMD3<Float>) in [Double(s.x), Double(s.y), Double(s.z)].map { ($0 * 1000).rounded() / 1000 } }
            return ["C1": v(c.c1), "C2": v(c.c2), "C3": v(c.c3), "H": v(c.halo), "swatch": v(c.swatch)]
        }
        func hex(_ s: SIMD3<Float>) -> String {
            String(format: "#%02x%02x%02x", Int((s.x * 255).rounded()), Int((s.y * 255).rounded()), Int((s.z * 255).rounded()))
        }
        // As the app colours them (ToastKind.color): working, needs, error, the theme's resting colour, done green.
        func toastColor(_ kind: ToastKind) -> SIMD3<Float> {
            switch kind {
            case .started, .resumed: pal[.working].swatch
            case .needs, .review, .usageLow: pal[.needs].swatch
            case .error, .usageCritical: pal[.error].swatch
            case .finished, .usageRefreshed, .catchUp, .update: pal[.idle].swatch
            case .allDone: OrbAnimator.doneGreen.swatch
            }
        }
        let story: [[String: Any]] = SimulatorStory.session.map { step in
            var s: [String: Any] = [
                // The story ends finished, which the orb shows as done.
                "state": step.state == .idle ? "done" : step.state.rawValue,
                "motion": step.motion.rawValue, "duration": step.duration, "subagents": step.subagents,
                "skill": step.skill, "detail": step.state == .working ? step.motion.summary : SimulatorStory.detail(for: step.state),
            ]
            if let end = step.endsPrevious { s["endsPrevious"] = end == .failed ? "failed" : "done" }
            if let left = step.usageLeft { s["usageLeft"] = left }
            if step.resetsUsage { s["resetsUsage"] = true }
            return s
        }
        let rest = IslandLayout.size(mode: .rest, dock: .top, rest: .live, pips: 3, rows: 3)
        let needs = IslandLayout.size(mode: .needs(""), dock: .top, rest: .live, pips: 3, rows: 3)
        let done = IslandLayout.size(mode: .done, dock: .top, rest: .live, pips: 3, rows: 3)
        let hover = IslandLayout.size(mode: .hover, dock: .top, rest: .live, pips: 3, rows: 3)
        let root: [String: Any] = [
            "version": version,
            "palette": [
                "idle": colors(pal[.idle]), "working": colors(pal[.working]), "needs": colors(pal[.needs]),
                "error": colors(pal[.error]), "done": colors(OrbAnimator.doneGreen),
            ],
            "motions": Dictionary(uniqueKeysWithValues: Motion.allCases.map {
                ($0.rawValue, ["work": $0.designWork, "verb": $0.verb, "summary": $0.summary])
            }),
            "story": story,
            "toasts": Dictionary(uniqueKeysWithValues: ToastKind.allCases.map {
                ($0.rawValue, ["text": $0.text, "color": hex(toastColor($0))])
            }),
            "island": [
                "cornerRadius": Double(IslandLayout.cornerRadius), "orbSize": Double(IslandLayout.orbSize),
                "barHeight": Double(IslandLayout.barHeight),
                "restWidth": Double(rest.width), "restHeight": Double(rest.height),
                "needsWidth": Double(needs.width), "needsHeight": Double(needs.height),
                "doneWidth": Double(done.width), "doneHeight": Double(done.height),
                "hoverWidth": Double(hover.width), "rowHeight": Double(IslandLayout.rowHeight),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
