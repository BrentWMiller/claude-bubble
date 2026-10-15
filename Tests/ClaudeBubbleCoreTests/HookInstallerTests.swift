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
                           "Notification", "Stop", "StopFailure"]
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

    func testInstallRefusesUnparseableSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh")))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
    }
}
