import Foundation

/// Adds the bubble hook to Claude Code's settings.json without disturbing existing hooks.
public enum HookInstaller {
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionDenied", "PermissionRequest", "Elicitation", "ElicitationResult",
        "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"
    ]

    public enum InstallError: LocalizedError {
        case unparseableSettings(URL)
        case missingHookScript

        public var errorDescription: String? {
            switch self {
            case .unparseableSettings(let url): "\(url.path) isn't valid JSON, so nothing was changed."
            case .missingHookScript: "The hook script is missing from the app bundle."
            }
        }
    }

    /// Seconds Claude Code lets the hook run: a moment to record, except a permission prompt, where the hook waits
    /// for an Allow or Deny click in the bubble (the terminal's prompt shows meanwhile).
    public static func timeout(for event: String) -> Int { event == "PermissionRequest" ? 600 : 5 }

    public static func merge(settings: [String: Any], command: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            // [Any], not [[String: Any]]: one unrecognised entry must not cost the user the whole list.
            var groups = hooks[event] as? [Any] ?? []
            var present = false
            for (g, group) in groups.enumerated() {
                guard var group = group as? [String: Any], var entries = group["hooks"] as? [[String: Any]] else { continue }
                for (e, entry) in entries.enumerated() where entry["command"] as? String == command {
                    present = true
                    // An older install's timeout is too short to wait for a click.
                    if (entry["timeout"] as? Int ?? 0) < timeout(for: event) { entries[e]["timeout"] = timeout(for: event) }
                }
                group["hooks"] = entries
                groups[g] = group
            }
            if !present {
                groups.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": timeout(for: event)]]])
            }
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// For settings that already run `command`: adds any events this version subscribes to that they lack, and
    /// raises timeouts that are now too short. Returns nil when nothing needs writing (or the hook was never
    /// installed, which this never does on its own).
    public static func refreshSubscriptions(settings: [String: Any], command: String) -> [String: Any]? {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        func ours(_ event: String) -> [[String: Any]] {
            (hooks[event] as? [Any] ?? []).flatMap { group in
                ((group as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).filter { $0["command"] as? String == command }
            }
        }
        func current(_ event: String) -> Bool {
            let entries = ours(event)
            return !entries.isEmpty && entries.allSatisfy { ($0["timeout"] as? Int ?? 0) >= timeout(for: event) }
        }
        guard events.contains(where: { !ours($0).isEmpty }), !events.allSatisfy(current) else { return nil }
        return merge(settings: settings, command: command)
    }

    /// At launch, brings an existing install up to date: any hook events it lacks, and the status line wrapper
    /// (which passes usage to the bubble). Returns nil when nothing needs writing or the hook was never installed
    /// (this never installs on its own). `inner` is the status line command to save for the wrapper, if it changed.
    public static func upgrade(settings: [String: Any], hookCommand: String, wrapper: String)
        -> (settings: [String: Any], inner: String?)? {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        let installed = hooks.values.contains { groups in
            (groups as? [Any] ?? []).contains { group in
                ((group as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == hookCommand }
            }
        }
        guard installed else { return nil }
        let events = refreshSubscriptions(settings: settings, command: hookCommand)
        let wrapped = wrapStatusLine(settings: events ?? settings, wrapper: wrapper)
        guard events != nil || wrapped.inner != nil else { return nil }
        return (wrapped.settings, wrapped.inner)
    }

    /// Points Claude Code's status line at the bubble's wrapper. Returns the command it replaced (the wrapper runs
    /// it, so the status line looks the same), "" when there was none, or nil when it was already wrapped
    /// (leave the saved command alone).
    public static func wrapStatusLine(settings: [String: Any], wrapper: String) -> (settings: [String: Any], inner: String?) {
        var settings = settings
        // A shape we don't understand is left exactly as it is.
        if let other = settings["statusLine"], !(other is [String: Any]) { return (settings, nil) }
        var line = settings["statusLine"] as? [String: Any] ?? [:]
        let existing = line["command"] as? String
        // Already wrapped, however the path is written: wrapping the wrapper would make it run itself forever.
        if let existing, existing == wrapper || existing.contains(".claude-bubble/statusline.sh") { return (settings, nil) }
        line["type"] = "command"
        line["command"] = wrapper
        settings["statusLine"] = line
        return (settings, existing ?? "")
    }

    /// After an app update, swaps in the bundled hook if one is already installed and differs.
    /// Never installs a hook the user hasn't installed. Returns whether it replaced the file.
    @discardableResult
    public static func refreshInstalledHook(source: URL, destination: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path), !fm.contentsEqual(atPath: source.path, andPath: destination.path) else {
            return false
        }
        let staged = destination.appendingPathExtension("new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        // replaceItemAt keeps the old file's metadata, so mark it executable afterwards.
        _ = try fm.replaceItemAt(destination, withItemAt: staged)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return true
    }

    /// Whether Claude Code is connected to the bubble: its hooks run ours, and its status line runs our wrapper.
    public struct Connection: Equatable {
        public var hooks: Bool
        public var statusLine: Bool
        public init(hooks: Bool, statusLine: Bool) {
            self.hooks = hooks
            self.statusLine = statusLine
        }
    }

    public static func connection(settings: [String: Any]) -> Connection {
        let hooks = (settings["hooks"] as? [String: Any] ?? [:]).values.contains { groups in
            (groups as? [Any] ?? []).contains { group in
                ((group as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains(".claude-bubble/hook.sh") == true
                }
            }
        }
        let line = ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(".claude-bubble/statusline.sh") == true
        return Connection(hooks: hooks, statusLine: line)
    }

    /// Settings without the bubble: every hook entry that runs our hook (groups and events left empty go too), and
    /// the status line back to what it was before we wrapped it (`inner`: the saved command, "" when there was
    /// none). Everything else is left exactly as it is.
    public static func removing(settings: [String: Any], hookCommand: String, inner: String?) -> [String: Any] {
        var settings = settings
        func ours(_ entry: Any) -> Bool {
            guard let c = (entry as? [String: Any])?["command"] as? String else { return false }
            return c == hookCommand || c.contains(".claude-bubble/hook.sh")
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for (event, value) in hooks {
                guard let groups = value as? [Any] else { continue }
                let kept: [Any] = groups.compactMap { group in
                    guard var g = group as? [String: Any], let entries = g["hooks"] as? [Any], entries.contains(where: ours) else {
                        return group
                    }
                    let rest = entries.filter { !ours($0) }
                    if rest.isEmpty { return nil }
                    g["hooks"] = rest
                    return g
                }
                hooks[event] = kept.isEmpty ? nil : kept
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
        }
        if var line = settings["statusLine"] as? [String: Any], let c = line["command"] as? String,
           c.contains(".claude-bubble/statusline.sh") {
            if let inner, !inner.isEmpty {
                line["command"] = inner
                settings["statusLine"] = line
            } else {
                settings["statusLine"] = nil
            }
        }
        return settings
    }

    /// Disconnects the bubble from Claude Code: our hooks out of settings.json (the real file, if it's a symlink) and
    /// the status line restored. Throws, changing nothing, if settings.json can't be read.
    public static func uninstall(settingsURL link: URL, bubbleDir: URL) throws {
        let fm = FileManager.default
        let settingsURL = link.resolvingSymlinksInPath()
        if fm.fileExists(atPath: settingsURL.path) {
            let data = try Data(contentsOf: settingsURL)
            guard data.isEmpty || ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil else {
                throw InstallError.unparseableSettings(settingsURL)
            }
            let settings = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
            let inner = (try? String(contentsOf: bubbleDir.appendingPathComponent("statusline-inner"), encoding: .utf8)) ?? ""
            let out = removing(settings: settings,
                               hookCommand: "\"\(bubbleDir.appendingPathComponent("hook.sh").path)\"",
                               inner: inner.trimmingCharacters(in: .whitespacesAndNewlines))
            let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
            try json.write(to: settingsURL, options: .atomic)
        }
        // hook.sh and the status line wrapper stay: Claude Code sessions already running keep calling them until
        // restarted. Without the binary, hook.sh does nothing; the wrapper still runs the user's own status line.
        for name in ["bin", "python-path"] {
            try? fm.removeItem(at: bubbleDir.appendingPathComponent(name))
        }
    }

    /// Uninstalling the app: disconnects from Claude Code, then deletes `bubbleDir` (sessions, usage, hook, binary,
    /// wrapper). If settings.json can't be read, it throws and deletes nothing, since its hooks would still point here.
    public static func uninstallEverything(settingsURL: URL, bubbleDir: URL) throws {
        try uninstall(settingsURL: settingsURL, bubbleDir: bubbleDir)
        if FileManager.default.fileExists(atPath: bubbleDir.path) {
            try FileManager.default.removeItem(at: bubbleDir)
        }
    }

    /// Puts the hook binary in place (install, or an app update): runnable, and without the quarantine flag a
    /// downloaded zip leaves on it, which would make Gatekeeper refuse to run it from the hook. Returns whether it
    /// changed anything.
    @discardableResult
    public static func installBinary(source: URL, destination: URL) throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path), fm.contentsEqual(atPath: source.path, andPath: destination.path) {
            return false
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.appendingPathExtension("new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        removexattr(staged.path, "com.apple.quarantine", 0)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        // Rename over it, so a hook firing mid-update runs the old binary or the new one, never half of one.
        guard rename(staged.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        return true
    }

    public static func install(settingsURL link: URL, hookSource: URL, hookDestination: URL,
                               statusLineSource: URL? = nil, statusLineDestination: URL? = nil) throws {
        let fm = FileManager.default
        // Dotfile setups symlink settings.json; edit the real file so the link survives.
        let settingsURL = link.resolvingSymlinksInPath()
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            if !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw InstallError.unparseableSettings(settingsURL)
                }
                settings = parsed
            }
            // Keep the first backup: it's the only copy of the settings from before the bubble existed.
            let backup = link.appendingPathExtension("claude-bubble.bak")
            if !fm.fileExists(atPath: backup.path) {
                try fm.copyItem(at: settingsURL, to: backup)
            }
        }

        try fm.createDirectory(at: hookDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: hookDestination)
        try fm.copyItem(at: hookSource, to: hookDestination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookDestination.path)

        var merged = merge(settings: settings, command: "\"\(hookDestination.path)\"")
        if let source = statusLineSource, let destination = statusLineDestination {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let wrapped = wrapStatusLine(settings: merged, wrapper: "\"\(destination.path)\"")
            merged = wrapped.settings
            if let inner = wrapped.inner {
                try inner.write(to: destination.deletingLastPathComponent().appendingPathComponent("statusline-inner"),
                                atomically: true, encoding: .utf8)
            }
        }
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }
}
