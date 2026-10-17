import XCTest
@testable import ClaudeBubbleCore

final class HookInstallerTests: XCTestCase {
    let cmd = "\"/Users/me/.claude-bubble/hook.sh\""
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func commands(_ settings: [String: Any], _ event: String) -> [String] {
        let groups = ((settings["hooks"] as? [String: Any])?[event] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testMergeIntoEmptyAddsEveryEvent() {
        let out = HookInstaller.merge(settings: [:], command: cmd)
        for event in HookInstaller.events { XCTAssertEqual(commands(out, event), [cmd], event) }
    }

    func testSubscribesToEveryEventTheHookMaps() {
        let mapped: Set = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                           "PostToolUseFailure", "PermissionDenied", "PermissionRequest", "Elicitation", "ElicitationResult",
                           "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
        XCTAssertEqual(Set(HookInstaller.events), mapped)
    }

    func testMergeKeepsExistingHooksAndOtherKeys() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "peon.sh"]]]]]
        ]
        let out = HookInstaller.merge(settings: existing, command: cmd)
        XCTAssertEqual(out["model"] as? String, "opus")
        XCTAssertEqual(commands(out, "Stop"), ["peon.sh", cmd])
    }

    func testMergeKeepsUnrecognisedEntries() {
        let existing: [String: Any] = ["hooks": ["Stop": ["legacy-string-entry", ["matcher": "", "hooks": [["type": "command", "command": "peon.sh"]]]]]]
        let out = HookInstaller.merge(settings: existing, command: cmd)
        let stop = (out["hooks"] as? [String: Any])?["Stop"] as? [Any] ?? []
        XCTAssertEqual(stop.count, 3)
        XCTAssertEqual(stop.first as? String, "legacy-string-entry")
        XCTAssertEqual(commands(out, "Stop"), ["peon.sh", cmd])
    }

    func testMergeIsIdempotent() {
        let once = HookInstaller.merge(settings: [:], command: cmd)
        let twice = HookInstaller.merge(settings: once, command: cmd)
        for event in HookInstaller.events { XCTAssertEqual(commands(twice, event), [cmd], event) }
    }

    func makeHook() throws -> URL {
        let src = dir.appendingPathComponent("src-hook.sh")
        try "#!/bin/bash\nexit 0\n".write(to: src, atomically: true, encoding: .utf8)
        return src
    }

    func testInstallCreatesMissingSettings() throws {
        let settings = dir.appendingPathComponent("claude/settings.json")
        let dest = dir.appendingPathComponent("bubble/hook.sh")
        try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dest)

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(commands(json, "UserPromptSubmit"), ["\"\(dest.path)\""])
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))
    }

    func testInstallTreatsEmptyFileAsEmptySettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try Data().write(to: settings)
        try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertNotNil(json["hooks"])
    }

    func testInstallBacksUpExistingSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"model":"opus"}"#.write(to: settings, atomically: true, encoding: .utf8)
        try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh"))
        let backup = try String(contentsOf: dir.appendingPathComponent("settings.json.claude-bubble.bak"), encoding: .utf8)
        XCTAssertEqual(backup, #"{"model":"opus"}"#)
    }

    func testReinstallKeepsTheOriginalBackup() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"model":"opus"}"#.write(to: settings, atomically: true, encoding: .utf8)
        try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh"))
        try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh"))
        let backup = try String(contentsOf: dir.appendingPathComponent("settings.json.claude-bubble.bak"), encoding: .utf8)
        XCTAssertEqual(backup, #"{"model":"opus"}"#)
    }

    func testInstallWritesThroughSymlinkedSettings() throws {
        let real = dir.appendingPathComponent("dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"opus"}"#.write(to: real, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try HookInstaller.install(settingsURL: link, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh"))

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as! [String: Any]
        XCTAssertEqual(json["model"] as? String, "opus")
        XCTAssertNotNil(json["hooks"])
    }

    func testRefreshReplacesAnOutdatedInstalledHook() throws {
        let dest = dir.appendingPathComponent("hook.sh")
        try "#!/bin/bash\n# old\n".write(to: dest, atomically: true, encoding: .utf8)
        XCTAssertTrue(try HookInstaller.refreshInstalledHook(source: try makeHook(), destination: dest))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "#!/bin/bash\nexit 0\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))
    }

    func testRefreshLeavesACurrentHookAlone() throws {
        let dest = dir.appendingPathComponent("hook.sh")
        try FileManager.default.copyItem(at: try makeHook(), to: dest)
        XCTAssertFalse(try HookInstaller.refreshInstalledHook(source: try makeHook(), destination: dest))
    }

    func testRefreshNeverInstallsAHookTheUserDidNotInstall() throws {
        let dest = dir.appendingPathComponent("hook.sh")
        XCTAssertFalse(try HookInstaller.refreshInstalledHook(source: try makeHook(), destination: dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testInstallRefusesUnparseableSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh")))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
    }

    // Status line wrapper

    let wrapper = "\"/Users/me/.claude-bubble/statusline.sh\""

    func testWrapStatusLineSavesTheOriginalCommand() {
        let existing: [String: Any] = ["model": "opus",
                                       "statusLine": ["type": "command", "command": "bash ~/.claude/line.sh", "padding": 2]]
        let out = HookInstaller.wrapStatusLine(settings: existing, wrapper: wrapper)
        let line = out.settings["statusLine"] as? [String: Any]
        XCTAssertEqual(line?["command"] as? String, wrapper)
        XCTAssertEqual(line?["type"] as? String, "command")
        XCTAssertEqual(line?["padding"] as? Int, 2)
        XCTAssertEqual(out.settings["model"] as? String, "opus")
        XCTAssertEqual(out.inner, "bash ~/.claude/line.sh")
    }

    func testWrapStatusLineWithNoStatusLine() {
        let out = HookInstaller.wrapStatusLine(settings: [:], wrapper: wrapper)
        XCTAssertEqual((out.settings["statusLine"] as? [String: Any])?["command"] as? String, wrapper)
        XCTAssertEqual(out.inner, "")
    }

    func testWrapStatusLineNeverWrapsItself() {
        let existing: [String: Any] = ["statusLine": ["type": "command", "command": wrapper]]
        let out = HookInstaller.wrapStatusLine(settings: existing, wrapper: wrapper)
        XCTAssertEqual((out.settings["statusLine"] as? [String: Any])?["command"] as? String, wrapper)
        XCTAssertNil(out.inner, "leave the saved inner command alone")
    }

    func testInstallIsIdempotent() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try #"{"statusLine":{"type":"command","command":"echo mine"}}"#.write(to: settings, atomically: true, encoding: .utf8)
        let source = dir.appendingPathComponent("src-statusline.sh")
        try "#!/bin/bash\n".write(to: source, atomically: true, encoding: .utf8)
        let dest = dir.appendingPathComponent("bubble/statusline.sh")
        for _ in 0..<2 {
            try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("bubble/hook.sh"),
                                      statusLineSource: source, statusLineDestination: dest)
        }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual((json["statusLine"] as? [String: Any])?["command"] as? String, "\"\(dest.path)\"")
        let inner = try String(contentsOf: dir.appendingPathComponent("bubble/statusline-inner"), encoding: .utf8)
        XCTAssertEqual(inner, "echo mine")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))
    }

    func testWrapStatusLineRecognisesTheWrapperInAnyForm() {
        for form in ["~/.claude-bubble/statusline.sh", "/Users/me/.claude-bubble/statusline.sh", "bash \"$HOME/.claude-bubble/statusline.sh\""] {
            let out = HookInstaller.wrapStatusLine(settings: ["statusLine": ["type": "command", "command": form]], wrapper: wrapper)
            XCTAssertNil(out.inner, form)
        }
    }

    func testWrapStatusLineLeavesAnUnknownShapeAlone() {
        let out = HookInstaller.wrapStatusLine(settings: ["statusLine": "weird"], wrapper: wrapper)
        XCTAssertEqual(out.settings["statusLine"] as? String, "weird")
        XCTAssertNil(out.inner)
    }

    func testRefreshAddsMissingEventsOnlyWhenInstalled() {
        let old: [String: Any] = ["hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": cmd]]]]]]
        let refreshed = HookInstaller.refreshSubscriptions(settings: old, command: cmd)
        XCTAssertEqual(commands(refreshed ?? [:], "SubagentStart"), [cmd])
        XCTAssertNil(HookInstaller.refreshSubscriptions(settings: refreshed!, command: cmd), "nothing missing: no write")
        XCTAssertNil(HookInstaller.refreshSubscriptions(settings: ["model": "opus"], command: cmd), "never installs on its own")
    }

    // Launch-time upgrade of an existing install

    func testUpgradeWrapsTheStatusLineOfAnExistingInstall() throws {
        let old: [String: Any] = ["hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": cmd]]]]],
                                  "statusLine": ["type": "command", "command": "bash ~/.claude/line.sh"]]
        let up = try XCTUnwrap(HookInstaller.upgrade(settings: old, hookCommand: cmd, wrapper: wrapper))
        XCTAssertEqual((up.settings["statusLine"] as? [String: Any])?["command"] as? String, wrapper)
        XCTAssertEqual(up.inner, "bash ~/.claude/line.sh")
        XCTAssertEqual(commands(up.settings, "SubagentStart"), [cmd], "missing events too")
    }

    func testUpgradeLeavesAnUpToDateInstallAlone() {
        var settings = HookInstaller.merge(settings: [:], command: cmd)
        settings["statusLine"] = ["type": "command", "command": wrapper]
        XCTAssertNil(HookInstaller.upgrade(settings: settings, hookCommand: cmd, wrapper: wrapper))
    }

    func testUpgradeNeverInstallsOnItsOwn() {
        XCTAssertNil(HookInstaller.upgrade(settings: ["statusLine": ["type": "command", "command": "x"]], hookCommand: cmd, wrapper: wrapper))
    }

    func testUpgradeOnlyEventsKeepsTheStatusLine() throws {
        let old: [String: Any] = ["hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": cmd]]]]],
                                  "statusLine": ["type": "command", "command": wrapper]]
        let up = try XCTUnwrap(HookInstaller.upgrade(settings: old, hookCommand: cmd, wrapper: wrapper))
        XCTAssertNil(up.inner, "already wrapped: leave the saved inner command alone")
    }

    // The hook binary

    func testInstallBinaryCopiesItRunnableAndUnquarantined() throws {
        let source = dir.appendingPathComponent("claude-bubble-hook")
        try Data("binary".utf8).write(to: source)
        // A file from a downloaded zip carries a quarantine flag; Gatekeeper would refuse to run the copy.
        XCTAssertEqual(setxattr(source.path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0), 0)
        let dest = dir.appendingPathComponent("bin/claude-bubble-hook")
        XCTAssertTrue(try HookInstaller.installBinary(source: source, destination: dest))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dest.path))
        XCTAssertEqual(getxattr(dest.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "quarantine stripped")
        XCTAssertFalse(try HookInstaller.installBinary(source: source, destination: dest), "already current")
        try Data("newer".utf8).write(to: source)
        XCTAssertTrue(try HookInstaller.installBinary(source: source, destination: dest))
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "newer")
    }

    // Disconnecting

    func testRemovingTakesOutOnlyOurHooks() {
        let mine: [String: Any] = ["type": "command", "command": "afplay ding.aiff"]
        var settings = HookInstaller.merge(settings: ["model": "opus", "hooks": ["Stop": [["matcher": "", "hooks": [mine]]]]],
                                           command: cmd)
        // Ours sharing a group with someone else's.
        var hooks = settings["hooks"] as! [String: Any]
        hooks["PreToolUse"] = [["matcher": "Bash", "hooks": [mine, ["type": "command", "command": cmd]]]]
        settings["hooks"] = hooks
        let out = HookInstaller.removing(settings: settings, hookCommand: cmd, inner: nil)
        XCTAssertEqual(out["model"] as? String, "opus")
        XCTAssertEqual(commands(out, "Stop"), ["afplay ding.aiff"])
        XCTAssertEqual(commands(out, "PreToolUse"), ["afplay ding.aiff"])
        XCTAssertNil((out["hooks"] as? [String: Any])?["SessionStart"], "events left empty are dropped")
        XCTAssertEqual(((out["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])?.first?["matcher"] as? String, "Bash")
    }

    func testRemovingDropsAnEmptyHooksKey() {
        let out = HookInstaller.removing(settings: HookInstaller.merge(settings: [:], command: cmd), hookCommand: cmd, inner: nil)
        XCTAssertNil(out["hooks"])
    }

    func testRemovingRestoresTheStatusLine() {
        let wrapper = "\"/Users/me/.claude-bubble/statusline.sh\""
        let wrapped: [String: Any] = ["statusLine": ["type": "command", "command": wrapper, "padding": 0]]
        let restored = HookInstaller.removing(settings: wrapped, hookCommand: cmd, inner: "~/bin/line.sh")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/line.sh")
        XCTAssertEqual((restored["statusLine"] as? [String: Any])?["padding"] as? Int, 0)
        XCTAssertNil(HookInstaller.removing(settings: wrapped, hookCommand: cmd, inner: "")["statusLine"], "there was none before")
        let theirs: [String: Any] = ["statusLine": ["type": "command", "command": "~/bin/line.sh"]]
        XCTAssertEqual((HookInstaller.removing(settings: theirs, hookCommand: cmd, inner: nil)["statusLine"] as? [String: Any])?["command"] as? String,
                       "~/bin/line.sh", "a status line that isn't ours is left alone")
    }

    func testUninstallWritesThroughASymlinkAndRemovesOurFiles() throws {
        let real = dir.appendingPathComponent("dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bubble = dir.appendingPathComponent(".claude-bubble")
        try FileManager.default.createDirectory(at: bubble.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let hook = bubble.appendingPathComponent("hook.sh").path
        let settings = HookInstaller.merge(settings: ["statusLine": ["type": "command", "command": "\"\(bubble.path)/statusline.sh\""]],
                                           command: "\"\(hook)\"")
        try JSONSerialization.data(withJSONObject: settings).write(to: real)
        let link = dir.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        for f in ["hook.sh", "statusline.sh", "bin/claude-bubble-hook", "python-path"] {
            try Data().write(to: bubble.appendingPathComponent(f))
        }
        try "~/bin/line.sh".write(to: bubble.appendingPathComponent("statusline-inner"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: bubble.appendingPathComponent("sessions"), withIntermediateDirectories: true)

        try HookInstaller.uninstall(settingsURL: link, bubbleDir: bubble)

        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: real)) as? [String: Any])
        XCTAssertNil(out["hooks"])
        XCTAssertEqual((out["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/line.sh")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "the link survives")
        for f in ["bin", "python-path"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bubble.appendingPathComponent(f).path), f)
        }
        // Sessions already running keep calling these until restarted: they stay, as harmless no-ops.
        for f in ["hook.sh", "statusline.sh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: bubble.appendingPathComponent(f).path), f)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bubble.appendingPathComponent("sessions").path))
    }

    // Setup checklist

    func testConnectionStatus() {
        XCTAssertEqual(HookInstaller.connection(settings: [:]), .init(hooks: false, statusLine: false))
        let hooked = HookInstaller.merge(settings: [:], command: cmd)
        XCTAssertEqual(HookInstaller.connection(settings: hooked), .init(hooks: true, statusLine: false))
        var both = hooked
        both["statusLine"] = ["type": "command", "command": "\"/Users/me/.claude-bubble/statusline.sh\""]
        XCTAssertEqual(HookInstaller.connection(settings: both), .init(hooks: true, statusLine: true))
    }

    func testUninstallRefusesUnreadableSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try "{not json".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.uninstall(settingsURL: settings, bubbleDir: dir.appendingPathComponent(".claude-bubble")))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{not json", "left untouched")
    }

    // Uninstalling the app

    func testUninstallEverythingDisconnectsAndRemovesTheFolder() throws {
        let bubble = dir.appendingPathComponent(".claude-bubble")
        try FileManager.default.createDirectory(at: bubble.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data().write(to: bubble.appendingPathComponent("hook.sh"))
        try "~/bin/line.sh".write(to: bubble.appendingPathComponent("statusline-inner"), atomically: true, encoding: .utf8)
        let settingsURL = dir.appendingPathComponent("settings.json")
        let settings = HookInstaller.merge(settings: ["model": "opus", "statusLine": ["type": "command", "command": "\"\(bubble.path)/statusline.sh\""]],
                                           command: "\"\(bubble.path)/hook.sh\"")
        try JSONSerialization.data(withJSONObject: settings).write(to: settingsURL)

        try HookInstaller.uninstallEverything(settingsURL: settingsURL, bubbleDir: bubble)

        let out = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        XCTAssertNil(out["hooks"])
        XCTAssertEqual(out["model"] as? String, "opus")
        XCTAssertEqual((out["statusLine"] as? [String: Any])?["command"] as? String, "~/bin/line.sh", "restored before the folder went")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bubble.path))
    }

    func testUninstallEverythingKeepsTheFolderIfSettingsCantBeRead() throws {
        let bubble = dir.appendingPathComponent(".claude-bubble")
        try FileManager.default.createDirectory(at: bubble, withIntermediateDirectories: true)
        let settingsURL = dir.appendingPathComponent("settings.json")
        try "{oops".write(to: settingsURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.uninstallEverything(settingsURL: settingsURL, bubbleDir: bubble))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bubble.path), "hooks still point here: don't pull the files out from under them")
    }
}
