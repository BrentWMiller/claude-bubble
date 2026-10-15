import Foundation

/// Adds the bubble hook to Claude Code's settings.json without disturbing existing hooks.
public enum HookInstaller {
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionDenied", "PermissionRequest", "Elicitation", "ElicitationResult",
        "Notification", "Stop", "StopFailure"
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

    public static func merge(settings: [String: Any], command: String) -> [String: Any] {
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            // [Any], not [[String: Any]]: one unrecognised entry must not cost the user the whole list.
            var groups = hooks[event] as? [Any] ?? []
            let present = groups.contains { group in
                ((group as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
            if !present {
                groups.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 5]]])
            }
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
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
