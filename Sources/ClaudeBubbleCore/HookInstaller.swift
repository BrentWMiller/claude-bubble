import Foundation

/// Adds the bubble hook to Claude Code's settings.json without disturbing existing hooks.
public enum HookInstaller {
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionDenied", "PermissionRequest", "Notification", "Stop", "StopFailure"
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
            var groups = hooks[event] as? [[String: Any]] ?? []
            let present = groups.contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
            }
            if !present {
                groups.append(["matcher": "", "hooks": [["type": "command", "command": command, "timeout": 5]]])
            }
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        return settings
    }

    public static func install(settingsURL: URL, hookSource: URL, hookDestination: URL) throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            if !data.isEmpty {
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw InstallError.unparseableSettings(settingsURL)
                }
                settings = parsed
            }
            let backup = settingsURL.appendingPathExtension("claude-bubble.bak")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: settingsURL, to: backup)
        }

        try fm.createDirectory(at: hookDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: hookDestination)
        try fm.copyItem(at: hookSource, to: hookDestination)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookDestination.path)

        let merged = merge(settings: settings, command: "\"\(hookDestination.path)\"")
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }
}
