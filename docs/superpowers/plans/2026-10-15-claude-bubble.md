# Claude Bubble Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that floats a Metal-rendered particle orb showing whether any Claude Code session is idle, working, waiting on the user, or errored.

**Architecture:** A Claude Code hook script writes one JSON file per session to `~/.claude-bubble/sessions/`. A pure-Swift core library (`ClaudeBubbleCore`) does four jobs:
- loads those files and combines them into one state;
- eases the orb's animation parameters (a port of the design's JS);
- generates the sphere's points;
- merges the hook entries into `~/.claude/settings.json`.

A thin AppKit executable (`ClaudeBubble`) hosts an `MTKView` in a floating `NSPanel`. It renders two Metal pipelines that port the design's GLSL shaders, and adds a status-bar menu.

**Tech Stack:** Swift 5.10 language mode (Swift 6.4 toolchain), Swift Package Manager, AppKit, MetalKit (shaders compiled at runtime from source), XCTest, bash + `/usr/bin/python3` for the hook.

**Spec:** `docs/superpowers/specs/2026-10-15-claude-bubble-design.md`

## Global Constraints

- macOS 14+ (`platforms: [.macOS(.v14)]`), `swift-tools-version: 5.10`, no third-party dependencies.
- Orb parameters must match `PAL.claude` and `MOTION` from `~/Downloads/Claude session status indicator/orbParticles.js` exactly.
- Easing `k = 1 - 0.02^dt`, dt clamped to 0.05; bounce spring `bv += (-bounce*220 - bv*14)*dt`; needs bounce starts at `-0.28`.
- 5,200 Fibonacci-sphere points.
- Priority error > needs > working > idle. Sessions are stale after 15 min (needs: 60 min). Files older than 24 h are deleted.
- The hook always exits 0, never writes stdout, writes atomically, and uses a settings timeout of 5 s.
- The installer never removes existing hooks, is idempotent, backs up to `settings.json.claude-bubble.bak`, and aborts on unparseable JSON.
- Window 120 pt, orb diameter 72 pt (0.6 × window). Default position is bottom-center, `visibleFrame.minY + 56`.
- Commits: no AI attribution lines.

## Review Focus

1. Terminal closed mid-task (no `SessionEnd`): the orb must fall back to idle after 15 min, not stay "working" forever. Pinned in Task 1, `testStaleWorkingIsIgnored`.
2. `~/.claude/settings.json` missing or empty: the installer creates or fills it instead of failing. Pinned in Task 4, `testInstallCreatesMissingSettings` and `testInstallTreatsEmptyFileAsEmptySettings`.
3. Malformed hook input (garbage stdin, missing or path-like `session_id`): the hook exits 0 silently and writes nothing outside the sessions dir. Pinned in Task 2's hostile-input checks.
4. Saved bubble position on a display that's since been unplugged: the bubble must reappear at the default spot. Pinned in Task 4, `testSavedOriginOffScreenFallsBack`.
5. Permission approved and Claude continues: the orb must leave "needs you" and go back to "working". Pinned in Task 2 (`PostToolUse -> working`).

---

### Task 1: Package scaffold, BubbleState, SessionStore

**Files:**
- Create: `Package.swift`
- Create: `Sources/ClaudeBubbleCore/BubbleState.swift`
- Create: `Sources/ClaudeBubbleCore/SessionStore.swift`
- Create: `Sources/ClaudeBubble/main.swift` (placeholder so the package builds; replaced in Task 5)
- Test: `Tests/ClaudeBubbleCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum BubbleState: String { idle, working, needs, error }` with `priority: Int`
  - `struct Session(id:state:cwd:updatedAt:)`
  - `SessionStore.load(from: URL, now: Date) -> [Session]`
  - `SessionStore.aggregate(_: [Session], now: Date) -> BubbleState`
  - `SessionStore.defaultDirectory: URL`

- [ ] **Step 1: Write Package.swift and placeholder main**

```swift
// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "ClaudeBubble",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(name: "ClaudeBubbleCore", path: "Sources/ClaudeBubbleCore"),
        .executableTarget(
            name: "ClaudeBubble",
            dependencies: ["ClaudeBubbleCore"],
            path: "Sources/ClaudeBubble"
        ),
        .testTarget(
            name: "ClaudeBubbleCoreTests",
            dependencies: ["ClaudeBubbleCore"],
            path: "Tests/ClaudeBubbleCoreTests"
        )
    ]
)
```

`Sources/ClaudeBubble/main.swift`:
```swift
import ClaudeBubbleCore
```

- [ ] **Step 2: Write the failing tests**

`Tests/ClaudeBubbleCoreTests/SessionStoreTests.swift`:
```swift
import XCTest
@testable import ClaudeBubbleCore

final class SessionStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func session(_ state: BubbleState, ageMinutes: Double = 0) -> Session {
        Session(id: UUID().uuidString, state: state, updatedAt: now.addingTimeInterval(-ageMinutes * 60))
    }

    func testNoSessionsIsIdle() {
        XCTAssertEqual(SessionStore.aggregate([], now: now), .idle)
    }

    func testPriorityErrorOverNeedsOverWorkingOverIdle() {
        XCTAssertEqual(SessionStore.aggregate([session(.idle), session(.working)], now: now), .working)
        XCTAssertEqual(SessionStore.aggregate([session(.working), session(.needs), session(.idle)], now: now), .needs)
        XCTAssertEqual(SessionStore.aggregate([session(.needs), session(.error), session(.working)], now: now), .error)
    }

    func testStaleWorkingIsIgnored() {
        XCTAssertEqual(SessionStore.aggregate([session(.working, ageMinutes: 16)], now: now), .idle)
        XCTAssertEqual(SessionStore.aggregate([session(.working, ageMinutes: 14)], now: now), .working)
    }

    func testNeedsStaysLiveForAnHour() {
        XCTAssertEqual(SessionStore.aggregate([session(.needs, ageMinutes: 30)], now: now), .needs)
        XCTAssertEqual(SessionStore.aggregate([session(.needs, ageMinutes: 61)], now: now), .idle)
    }

    func testLoadReadsValidFilesAndSkipsJunk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = now.timeIntervalSince1970
        try #"{"state":"working","cwd":"/x","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("good.json"), atomically: true, encoding: .utf8)
        try "{not json".write(to: dir.appendingPathComponent("corrupt.json"), atomically: true, encoding: .utf8)
        try #"{"state":"dancing","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("unknown.json"), atomically: true, encoding: .utf8)
        try #"{"state":"needs","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent(".tmp-abc"), atomically: true, encoding: .utf8)
        try #"{"state":"needs","updated_at":\#(t)}"#.write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let sessions = SessionStore.load(from: dir, now: now)

        XCTAssertEqual(sessions, [Session(id: "good", state: .working, cwd: "/x", updatedAt: now)])
    }

    func testLoadDeletesFilesOlderThanADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("old.json")
        try #"{"state":"idle","updated_at":\#(now.timeIntervalSince1970 - 25 * 3600)}"#.write(to: old, atomically: true, encoding: .utf8)

        XCTAssertEqual(SessionStore.load(from: dir, now: now), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    func testLoadFromMissingDirectoryIsEmpty() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(SessionStore.load(from: dir, now: now), [])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter SessionStoreTests`
Expected: compile failure, "cannot find 'Session' in scope".

- [ ] **Step 4: Implement**

`Sources/ClaudeBubbleCore/BubbleState.swift`:
```swift
public enum BubbleState: String, CaseIterable, Sendable {
    case idle, working, needs, error

    /// Higher wins when several sessions disagree.
    public var priority: Int {
        switch self {
        case .idle: 0
        case .working: 1
        case .needs: 2
        case .error: 3
        }
    }
}
```

`Sources/ClaudeBubbleCore/SessionStore.swift`:
```swift
import Foundation

public struct Session: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    public let cwd: String
    public let updatedAt: Date

    public init(id: String, state: BubbleState, cwd: String = "", updatedAt: Date) {
        self.id = id
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
    }
}

/// Reads the per-session files written by the hook and reduces them to one state.
public enum SessionStore {
    public static let staleAfter: TimeInterval = 15 * 60
    public static let needsStaleAfter: TimeInterval = 60 * 60
    public static let deleteAfter: TimeInterval = 24 * 60 * 60

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-bubble/sessions", isDirectory: true)
    }

    private struct Record: Decodable {
        let state: String
        let cwd: String?
        let updated_at: Double
    }

    public static func load(from dir: URL, now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sessions: [Session] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let state = BubbleState(rawValue: record.state) else { continue }
            let updated = Date(timeIntervalSince1970: record.updated_at)
            if now.timeIntervalSince(updated) > deleteAfter {
                try? fm.removeItem(at: url)
                continue
            }
            sessions.append(Session(id: String(name.dropLast(5)), state: state, cwd: record.cwd ?? "", updatedAt: updated))
        }
        return sessions
    }

    public static func aggregate(_ sessions: [Session], now: Date = Date()) -> BubbleState {
        sessions
            .filter { now.timeIntervalSince($0.updatedAt) <= ($0.state == .needs ? needsStaleAfter : staleAfter) }
            .map(\.state)
            .max { $0.priority < $1.priority } ?? .idle
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SessionStoreTests`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: session store aggregates per-session hook state"
```

---

### Task 2: Hook script

**Files:**
- Create: `hook/claude-bubble-hook.sh`
- Test: `tests/hook_test.sh`

**Interfaces:**
- Consumes: the Claude Code hook JSON on stdin (`hook_event_name`, `session_id`, `cwd`, `notification_type`).
- Produces: `$CLAUDE_BUBBLE_DIR/sessions/<session_id>.json` = `{"state","event","cwd","updated_at","started_at"}`. `CLAUDE_BUBBLE_DIR` defaults to `~/.claude-bubble`. `CLAUDE_BUBBLE_REPLAY_WINDOW` defaults to 3 s and exists so tests can override it.

- [ ] **Step 1: Write the failing test**

`tests/hook_test.sh`:
```bash
#!/bin/bash
# Exercises hook/claude-bubble-hook.sh against a temp sessions dir.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hook/claude-bubble-hook.sh"
export CLAUDE_BUBBLE_DIR="$(mktemp -d)"
export CLAUDE_BUBBLE_REPLAY_WINDOW=0
S="$CLAUDE_BUBBLE_DIR/sessions"
fail=0

send() { printf '%s' "$1" | "$HOOK"; }
state_of() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["state"])' "$S/$1.json" 2>/dev/null || echo "<none>"; }
expect() {
  local got; got=$(state_of "$1")
  if [ "$got" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3: expected $2, got $got"; fail=1; fi
}
check() { if eval "$1"; then echo "ok   $2"; else echo "FAIL $2"; fail=1; fi; }

send '{"hook_event_name":"SessionStart","session_id":"a","cwd":"/tmp"}'; expect a idle "SessionStart -> idle"
send '{"hook_event_name":"UserPromptSubmit","session_id":"a"}';            expect a working "UserPromptSubmit -> working"
send '{"hook_event_name":"PermissionRequest","session_id":"a"}';           expect a needs "PermissionRequest -> needs"
send '{"hook_event_name":"PostToolUse","session_id":"a"}';                 expect a working "PostToolUse -> working"
send '{"hook_event_name":"Notification","session_id":"a","notification_type":"permission_prompt"}'; expect a needs "permission_prompt -> needs"
send '{"hook_event_name":"Notification","session_id":"a","notification_type":"auth_success"}';      expect a needs "other notification ignored"
send '{"hook_event_name":"Stop","session_id":"a"}';                        expect a idle "Stop -> idle"
send '{"hook_event_name":"Notification","session_id":"a","notification_type":"idle_prompt"}';       expect a idle "idle_prompt -> idle"
send '{"hook_event_name":"PreToolUse","session_id":"a"}';                  expect a working "PreToolUse -> working"
send '{"hook_event_name":"StopFailure","session_id":"a"}';                 expect a error "StopFailure -> error"
send '{"hook_event_name":"SubagentStop","session_id":"a"}';                expect a error "unmapped event ignored"
send '{"hook_event_name":"SessionEnd","session_id":"a"}';                  expect a "<none>" "SessionEnd deletes file"

export CLAUDE_BUBBLE_REPLAY_WINDOW=3
send '{"hook_event_name":"SessionStart","session_id":"r"}'
send '{"hook_event_name":"PermissionRequest","session_id":"r"}';           expect r idle "replayed event inside window ignored"
send '{"hook_event_name":"UserPromptSubmit","session_id":"r"}';            expect r working "prompt inside window still counts"
export CLAUDE_BUBBLE_REPLAY_WINDOW=0

out=$(printf 'not json' | "$HOOK"; echo "exit=$?"); check '[ "$out" = "exit=0" ]' "garbage stdin exits 0 silently"
out=$(printf '' | "$HOOK"; echo "exit=$?");         check '[ "$out" = "exit=0" ]' "empty stdin exits 0 silently"
send '{"hook_event_name":"Stop","session_id":"../evil"}'; check '[ ! -e "$CLAUDE_BUBBLE_DIR/evil.json" ]' "path-like session id rejected"
send '{"hook_event_name":"Stop"}'
check '[ "$(ls -A "$S")" = "r.json" ]' "no stray files (missing id, temp files)"

rm -rf "$CLAUDE_BUBBLE_DIR"
[ $fail -eq 0 ] && echo "all hook tests passed"
exit $fail
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/hook_test.sh`
Expected: FAIL lines ("No such file or directory" for the hook).

- [ ] **Step 3: Implement**

`hook/claude-bubble-hook.sh`:
```bash
#!/bin/bash
# Claude Bubble hook: records per-session Claude Code state for the Claude Bubble app.
# Never blocks or fails Claude: output is discarded and the exit code is always 0.
DIR="${CLAUDE_BUBBLE_DIR:-$HOME/.claude-bubble}/sessions"

PY=$(cat <<'EOF'
import json, os, sys, tempfile, time

d = sys.argv[1]
window = float(os.environ.get('CLAUDE_BUBBLE_REPLAY_WINDOW', '3'))
data = json.load(sys.stdin)
event = data.get('hook_event_name', '')
sid = str(data.get('session_id', ''))
if not sid or '/' in sid or sid.startswith('.'):
    sys.exit(0)
path = os.path.join(d, sid + '.json')

if event == 'SessionEnd':
    try:
        os.remove(path)
    except FileNotFoundError:
        pass
    sys.exit(0)

if event == 'Notification':
    state = {'permission_prompt': 'needs', 'idle_prompt': 'idle'}.get(data.get('notification_type', ''))
else:
    state = {
        'SessionStart': 'idle',
        'UserPromptSubmit': 'working',
        'PreToolUse': 'working',
        'PostToolUse': 'working',
        'PermissionRequest': 'needs',
        'Stop': 'idle',
        'StopFailure': 'error',
    }.get(event)
if state is None:
    sys.exit(0)

now = time.time()
try:
    with open(path) as f:
        prev = json.load(f)
except Exception:
    prev = {}
started = now if event == 'SessionStart' else float(prev.get('started_at', 0))
# `claude -c` replays old events right after SessionStart; ignore them (peon-ping does the same).
if event not in ('SessionStart', 'UserPromptSubmit') and now - started < window:
    sys.exit(0)

os.makedirs(d, exist_ok=True)
record = {'state': state, 'event': event, 'cwd': data.get('cwd', ''), 'updated_at': now, 'started_at': started}
fd, tmp = tempfile.mkstemp(dir=d, prefix='.tmp-')
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(record, f)
    os.replace(tmp, path)
except Exception:
    try:
        os.remove(tmp)
    except OSError:
        pass
EOF
)

/usr/bin/python3 -c "$PY" "$DIR" >/dev/null 2>&1
exit 0
```

Then: `chmod +x hook/claude-bubble-hook.sh tests/hook_test.sh`

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/hook_test.sh`
Expected: every line `ok`, then "all hook tests passed", exit 0.

- [ ] **Step 5: Commit**

```bash
git add hook tests
git commit -m "feat: hook script writes per-session state files"
```

---

### Task 3: Orb parameters, animator, sphere geometry

**Files:**
- Create: `Sources/ClaudeBubbleCore/OrbParams.swift`
- Create: `Sources/ClaudeBubbleCore/OrbAnimator.swift`
- Create: `Sources/ClaudeBubbleCore/OrbGeometry.swift`
- Test: `Tests/ClaudeBubbleCoreTests/OrbAnimatorTests.swift`

**Interfaces:**
- Consumes: `BubbleState`.
- Produces:
  - `OrbParams` (c1, c2, c3, halo: `SIMD3<Float>`; energy, wave, glow, bright, ring, scale, glitch: `Float`), with `OrbParams.target(for:)` and `approached(_:k:)`
  - `OrbAnimator(state:random:)`, `setState(_:)`, `step(dt: Double) -> OrbFrame`, plus `current`, `bounce` and `shake`
  - `OrbFrame { params, phase, scale, glow, ring, shakeX }`
  - `OrbGeometry.pointCount` (5200) and `OrbGeometry.fibonacciSphere(count:) -> [Float]` (xyz triples)

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeBubbleCoreTests/OrbAnimatorTests.swift`:
```swift
import XCTest
@testable import ClaudeBubbleCore

final class OrbAnimatorTests: XCTestCase {
    func run(_ a: OrbAnimator, seconds: Double) {
        for _ in 0..<Int(seconds * 60) { _ = a.step(dt: 1.0 / 60) }
    }

    func testStartsAtTargetForInitialState() {
        XCTAssertEqual(OrbAnimator(state: .working).current, .target(for: .working))
    }

    func testEasesTowardNewState() {
        let a = OrbAnimator(state: .idle)
        a.setState(.working)
        run(a, seconds: 2)
        XCTAssertEqual(a.current.scale, 1, accuracy: 0.01)
        XCTAssertEqual(a.current.halo.z, 0.75, accuracy: 0.01)
    }

    func testNeedsBouncesThenSettles() {
        let a = OrbAnimator(state: .working)
        a.setState(.needs)
        XCTAssertEqual(a.bounce, -0.28)
        run(a, seconds: 3)
        XCTAssertEqual(a.bounce, 0, accuracy: 0.01)
    }

    func testErrorShakesOnEntryThenSettles() {
        let a = OrbAnimator(state: .working)
        a.setState(.error)
        XCTAssertEqual(a.shake, 1)
        run(a, seconds: 2)
        XCTAssertLessThan(a.shake, 0.01)
        XCTAssertEqual(a.step(dt: 1.0 / 60).shakeX, 0)
    }

    func testStartingInErrorDoesNotShake() {
        XCTAssertEqual(OrbAnimator(state: .error).shake, 0)
    }

    func testLargeFrameGapIsClamped() {
        let a = OrbAnimator(state: .idle)
        a.setState(.working)
        _ = a.step(dt: 10)
        XCTAssertLessThan(a.current.scale, 0.9)
    }

    func testErrorFlickerUsesInjectedRandom() {
        let a = OrbAnimator(state: .error, random: { 0 })
        let f = a.step(dt: 1.0 / 60)
        XCTAssertEqual(f.ring, OrbParams.target(for: .error).ring * 0.35, accuracy: 0.001)
    }

    func testSphereHasUnitPoints() {
        let pts = OrbGeometry.fibonacciSphere()
        XCTAssertEqual(pts.count, OrbGeometry.pointCount * 3)
        for i in stride(from: 0, to: pts.count, by: 3) {
            let len = (pts[i] * pts[i] + pts[i + 1] * pts[i + 1] + pts[i + 2] * pts[i + 2]).squareRoot()
            XCTAssertEqual(len, 1, accuracy: 0.0001)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OrbAnimatorTests`
Expected: compile failure, "cannot find 'OrbAnimator' in scope".

- [ ] **Step 3: Implement**

`Sources/ClaudeBubbleCore/OrbParams.swift`:
```swift
/// Per-state orb look. Values are copied from PAL.claude + MOTION in the design's orbParticles.js.
public struct OrbParams: Equatable, Sendable {
    public var c1, c2, c3, halo: SIMD3<Float>
    public var energy, wave, glow, bright, ring, scale, glitch: Float

    public init(c1: SIMD3<Float>, c2: SIMD3<Float>, c3: SIMD3<Float>, halo: SIMD3<Float>,
                energy: Float, wave: Float, glow: Float, bright: Float, ring: Float, scale: Float, glitch: Float) {
        self.c1 = c1; self.c2 = c2; self.c3 = c3; self.halo = halo
        self.energy = energy; self.wave = wave; self.glow = glow; self.bright = bright
        self.ring = ring; self.scale = scale; self.glitch = glitch
    }

    public static func target(for state: BubbleState) -> OrbParams {
        switch state {
        case .idle:
            OrbParams(c1: [0.62, 0.66, 0.82], c2: [0.4, 0.44, 0.62], c3: [0.8, 0.82, 0.95], halo: [0.16, 0.18, 0.34],
                      energy: 0.12, wave: 0.08, glow: 0.35, bright: 0.5, ring: 0.35, scale: 0.72, glitch: 0)
        case .working:
            OrbParams(c1: [1, 0.46, 0.2], c2: [0.56, 0.3, 1], c3: [1, 0.45, 0.72], halo: [0.3, 0.14, 0.75],
                      energy: 1, wave: 1, glow: 1, bright: 1, ring: 1, scale: 1, glitch: 0)
        case .needs:
            OrbParams(c1: [1, 0.72, 0.22], c2: [1, 0.38, 0.24], c3: [1, 0.86, 0.55], halo: [0.6, 0.24, 0.08],
                      energy: 0.22, wave: 0.18, glow: 0.85, bright: 0.75, ring: 0.9, scale: 1, glitch: 0)
        case .error:
            OrbParams(c1: [1, 0.2, 0.22], c2: [0.72, 0.08, 0.2], c3: [1, 0.55, 0.45], halo: [0.5, 0.03, 0.06],
                      energy: 0.08, wave: 0, glow: 0.75, bright: 0.8, ring: 0.85, scale: 0.9, glitch: 1)
        }
    }

    /// Moves every value a fraction `k` of the way toward `t`.
    public func approached(_ t: OrbParams, k: Float) -> OrbParams {
        func m(_ a: Float, _ b: Float) -> Float { a + (b - a) * k }
        func m(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> { a + (b - a) * k }
        return OrbParams(c1: m(c1, t.c1), c2: m(c2, t.c2), c3: m(c3, t.c3), halo: m(halo, t.halo),
                         energy: m(energy, t.energy), wave: m(wave, t.wave), glow: m(glow, t.glow),
                         bright: m(bright, t.bright), ring: m(ring, t.ring), scale: m(scale, t.scale),
                         glitch: m(glitch, t.glitch))
    }
}
```

`Sources/ClaudeBubbleCore/OrbAnimator.swift`:
```swift
import Foundation

public struct OrbFrame: Sendable {
    public var params: OrbParams
    public var phase: Float
    public var scale: Float
    public var glow: Float
    public var ring: Float
    /// Horizontal shake offset as a fraction of the view width.
    public var shakeX: Float
}

/// Port of OrbBase.stepCommon + OrbP.step from the design's JS.
public final class OrbAnimator {
    public private(set) var state: BubbleState
    public private(set) var current: OrbParams
    public private(set) var bounce: Float = 0
    public private(set) var shake: Float = 0
    private var bounceVelocity: Float = 0
    private var phase: Float
    private var time: Double = 0
    private let random: () -> Float

    public init(state: BubbleState = .idle, random: @escaping () -> Float = { Float.random(in: 0..<1) }) {
        self.state = state
        self.random = random
        current = .target(for: state)
        phase = random() * 20
        if state == .needs { bounce = -0.28 }
    }

    public func setState(_ new: BubbleState) {
        guard new != state else { return }
        if new == .needs { bounce = -0.28; bounceVelocity = 0 }
        if new == .error { shake = 1 }
        state = new
    }

    public func step(dt rawDt: Double) -> OrbFrame {
        let dt = Float(min(max(rawDt, 0), 0.05))
        time += Double(dt)
        let k = 1 - powf(0.02, dt)
        current = current.approached(.target(for: state), k: k)
        bounceVelocity += (-bounce * 220 - bounceVelocity * 14) * dt
        bounce += bounceVelocity * dt
        // Every shader phase multiplier is a multiple of 0.05, so wrapping at 400π keeps floats precise without a visible seam.
        phase = (phase + dt * (0.2 + current.energy * 1.5)).truncatingRemainder(dividingBy: 400 * .pi)
        shake *= powf(0.02, dt)

        var scale = current.scale * (1 + bounce)
        var glow = current.glow
        var ring = current.ring
        switch state {
        case .idle:
            let b = Float(sin(time * .pi / 2))
            scale *= 1 + 0.05 * b
            glow *= 0.7 + 0.3 * b
            ring *= 0.75 + 0.25 * b
        case .needs:
            let b = Float(sin(time * .pi / 1.4))
            glow *= 0.6 + 0.4 * b
            ring *= 0.8 + 0.2 * b
        case .error:
            if random() < 0.08 { ring *= 0.35 }
            glow *= 0.85 + 0.15 * Float(sin(time * 9))
        case .working:
            break
        }
        let shakeX = shake > 0.01 ? Float(sin(time * 70)) * shake * 0.04 : 0
        return OrbFrame(params: current, phase: phase, scale: scale, glow: glow, ring: ring, shakeX: shakeX)
    }
}
```

`Sources/ClaudeBubbleCore/OrbGeometry.swift`:
```swift
import Foundation

public enum OrbGeometry {
    public static let pointCount = 5200

    /// Evenly spread unit-sphere points as packed xyz triples.
    public static func fibonacciSphere(count: Int = pointCount) -> [Float] {
        let golden = Float.pi * (3 - Float(5).squareRoot())
        var out: [Float] = []
        out.reserveCapacity(count * 3)
        for i in 0..<count {
            let y = 1 - Float(i) / Float(count - 1) * 2
            let r = max(0, 1 - y * y).squareRoot()
            let t = golden * Float(i)
            out += [cos(t) * r, y, sin(t) * r]
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OrbAnimatorTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeBubbleCore Tests
git commit -m "feat: orb animator ports design easing, bounce and shake"
```

---

### Task 4: HookInstaller and BubblePlacement

**Files:**
- Create: `Sources/ClaudeBubbleCore/HookInstaller.swift`
- Create: `Sources/ClaudeBubbleCore/BubblePlacement.swift`
- Test: `Tests/ClaudeBubbleCoreTests/HookInstallerTests.swift`
- Test: `Tests/ClaudeBubbleCoreTests/BubblePlacementTests.swift`

**Interfaces:**
- Produces:
  - `HookInstaller.events: [String]`
  - `HookInstaller.merge(settings: [String: Any], command: String) -> [String: Any]`
  - `HookInstaller.install(settingsURL:hookSource:hookDestination:) throws`
  - `HookInstaller.InstallError`
  - `BubblePlacement.origin(saved: CGPoint?, size: CGFloat, screenFrames: [CGRect], mainVisibleFrame: CGRect) -> CGPoint`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeBubbleCoreTests/HookInstallerTests.swift`:
```swift
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
        let groups = (settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testMergeIntoEmptyAddsEveryEvent() {
        let out = HookInstaller.merge(settings: [:], command: cmd)
        for event in HookInstaller.events { XCTAssertEqual(commands(out, event), [cmd], event) }
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

    func testInstallRefusesUnparseableSettings() throws {
        let settings = dir.appendingPathComponent("settings.json")
        try "{ broken".write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try HookInstaller.install(settingsURL: settings, hookSource: try makeHook(), hookDestination: dir.appendingPathComponent("hook.sh")))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{ broken")
    }
}
```

`Tests/ClaudeBubbleCoreTests/BubblePlacementTests.swift`:
```swift
import XCTest
@testable import ClaudeBubbleCore

final class BubblePlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)

    func testDefaultIsBottomCenterAboveDock() {
        let o = BubblePlacement.origin(saved: nil, size: 120, screenFrames: [screen], mainVisibleFrame: visible)
        XCTAssertEqual(o, CGPoint(x: 660, y: 126))
    }

    func testSavedOriginOnScreenIsKept() {
        let o = BubblePlacement.origin(saved: CGPoint(x: 100, y: 500), size: 120, screenFrames: [screen], mainVisibleFrame: visible)
        XCTAssertEqual(o, CGPoint(x: 100, y: 500))
    }

    func testSavedOriginOffScreenFallsBack() {
        let o = BubblePlacement.origin(saved: CGPoint(x: 3000, y: 500), size: 120, screenFrames: [screen], mainVisibleFrame: visible)
        XCTAssertEqual(o, CGPoint(x: 660, y: 126))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter "HookInstallerTests|BubblePlacementTests"`
Expected: compile failure, "cannot find 'HookInstaller' in scope".

- [ ] **Step 3: Implement**

`Sources/ClaudeBubbleCore/HookInstaller.swift`:
```swift
import Foundation

/// Adds the bubble hook to Claude Code's settings.json without disturbing existing hooks.
public enum HookInstaller {
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PermissionRequest", "Notification", "Stop", "StopFailure"
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
```

`Sources/ClaudeBubbleCore/BubblePlacement.swift`:
```swift
import CoreGraphics

public enum BubblePlacement {
    /// Bottom-center, with the 72pt orb sitting ~80pt above the Dock.
    public static func defaultOrigin(visibleFrame: CGRect, size: CGFloat) -> CGPoint {
        CGPoint(x: visibleFrame.midX - size / 2, y: visibleFrame.minY + 56)
    }

    /// Uses the saved origin only if the bubble's center is still on a connected screen.
    public static func origin(saved: CGPoint?, size: CGFloat, screenFrames: [CGRect], mainVisibleFrame: CGRect) -> CGPoint {
        if let saved {
            let center = CGPoint(x: saved.x + size / 2, y: saved.y + size / 2)
            if screenFrames.contains(where: { $0.contains(center) }) { return saved }
        }
        return defaultOrigin(visibleFrame: mainVisibleFrame, size: size)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: all tests pass (7 + 8 + 7 + 3 = 25).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeBubbleCore Tests
git commit -m "feat: hook installer and bubble placement"
```

---

### Task 5: Metal orb, floating panel, menu bar, app bundle

**Files:**
- Create: `Sources/ClaudeBubbleCore/SessionWatcher.swift`
- Create: `Sources/ClaudeBubble/OrbShaders.swift`
- Create: `Sources/ClaudeBubble/OrbView.swift`
- Create: `Sources/ClaudeBubble/BubblePanel.swift`
- Create: `Sources/ClaudeBubble/AppDelegate.swift`
- Modify: `Sources/ClaudeBubble/main.swift` (replace placeholder)
- Create: `Resources/Info.plist`
- Create: `scripts/bundle.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: `build/ClaudeBubble.app`.

- [ ] **Step 1: SessionWatcher**

`Sources/ClaudeBubbleCore/SessionWatcher.swift`:
```swift
import Foundation

/// Watches the sessions directory and reports the combined state whenever it changes.
/// The 5s timer catches missed events and lets stale sessions age out.
public final class SessionWatcher {
    private let directory: URL
    private let onChange: (BubbleState) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var last: BubbleState?

    public init(directory: URL, onChange: @escaping (BubbleState) -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    public func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
            src.setEventHandler { [weak self] in self?.refresh() }
            src.setCancelHandler { close(fd) }
            src.resume()
            source = src
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    public func refresh() {
        let now = Date()
        let state = SessionStore.aggregate(SessionStore.load(from: directory, now: now), now: now)
        if state != last {
            last = state
            onChange(state)
        }
    }
}
```

- [ ] **Step 2: Shaders (line-for-line port of QFS/PVS/PFS)**

Port notes:
- `pow(x, 2.)` on a possibly negative `x` becomes `x*x`, because Metal's `pow` with a negative base is NaN.
- Reversed `smoothstep(a, b, x)` (a > b) becomes `1 - smoothstep(b, a, x)`.
- Metal's `[[position]]` has y pointing down, so it is flipped to match `gl_FragCoord`.

`Sources/ClaudeBubble/OrbShaders.swift`:
```swift
/// Metal port of the shaders in the design's orbParticles.js. Compiled at runtime.
enum OrbShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 c1, c2, c3, halo;
    float4 a;   // phase, scale, glow, ring
    float4 b;   // glitch, wave, bright, pointSize
    float4 c;   // resX, resY, shiftX, unused
};

struct QuadOut { float4 position [[position]]; };

vertex QuadOut quadVertex(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    QuadOut o; o.position = float4(p[vid], 0, 1); return o;
}

fragment float4 quadFragment(QuadOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float2 res = u.c.xy;
    float2 frag = float2(in.position.x, res.y - in.position.y);
    float2 uv = (frag - .5 * res) / res.y - float2(u.c.z, 0);
    float ph = u.a.x, sc = u.a.y, glowv = u.a.z, ringv = u.a.w, glitch = u.b.x;
    float3 C1 = u.c1.xyz, C2 = u.c2.xyz, C3 = u.c3.xyz, H = u.halo.xyz;

    float R = .3 * sc; float r = length(uv); float a = atan2(uv.y, uv.x);
    float k = .5 + .5 * sin(a * 1. + ph * .9); float k2 = .5 + .5 * sin(a * 2. - ph * .6 + 1.3);
    float3 rc = mix(mix(C1, C2, k), C3, k2 * .6);
    float w = .016 + .01 * sin(a * 3. + ph);
    float gap = step(.7, fract(sin(floor(a * 6. + ph * 4.) * 57.3) * 913.1));
    w *= 1. - glitch * gap * .7;
    float d1 = (r - R * 1.02) / w; float ring = exp(-d1 * d1);
    float d2 = (r - R * 1.05) / (w * 2.6); float fuzz = exp(-d2 * d2) * .45;
    float hl = pow(.5 + .5 * cos(a - ph * .8 - 1.2), 5.);
    float3 col = rc * (ring * (.55 + 1.6 * hl) + fuzz * (.4 + hl)) * ringv;
    col += float3(1.) * ring * hl * hl * .6 * ringv;
    float o = max(r - R, 0.);
    col += H * glowv * (exp(-o * 7.) * .55 + exp(-o * 22.) * .5) * smoothstep(R * .7, R * 1.02, r);
    col += H * glowv * .12 * (1. - smoothstep(0., R, r));
    col *= 1. - smoothstep(.36, .5, r);
    col = 1. - exp(-col * 1.4);
    return float4(col, max(col.r, max(col.g, col.b)));
}

struct PointOut {
    float4 position [[position]];
    float size [[point_size]];
    float3 color;
};

float3x3 ry(float a) { float c = cos(a), s = sin(a); return float3x3(float3(c, 0, -s), float3(0, 1, 0), float3(s, 0, c)); }
float3x3 rx(float a) { float c = cos(a), s = sin(a); return float3x3(float3(1, 0, 0), float3(0, c, s), float3(0, -s, c)); }

vertex PointOut pointVertex(uint vid [[vertex_id]],
                            constant Uniforms& u [[buffer(0)]],
                            const device packed_float3* pts [[buffer(1)]]) {
    float3 pos = float3(pts[vid]);
    float ph = u.a.x, sc = u.a.y, glitch = u.b.x, wave = u.b.y, bright = u.b.z, pt = u.b.w;
    float3 C1 = u.c1.xyz, C2 = u.c2.xyz, C3 = u.c3.xyz;

    float3 p = pos;
    float tw = wave * .9 * sin(p.y * 3.2 + ph * 1.3);
    p = ry(ph * .35 + tw) * p;
    float dd = dot(p, normalize(float3(.3, -.2, .9))) - .55;
    float wv = sin(dot(p, float3(.55, .8, .25)) * 7. - ph * 2.6) * exp(-dd * dd * 5.);
    p *= 1. + wave * .07 * wv;
    float gh = fract(sin(dot(pos + floor(ph * 9.), float3(12.9898, 78.233, 37.719))) * 43758.5453);
    float band = step(.82, fract(sin(floor((pos.y + ph * .3) * 9.) * 91.7) * 437.5));
    p *= 1. + glitch * (gh * .1 + band * .12);
    p.x += glitch * band * .08 * sign(gh - .5);
    p = rx(.35) * p;
    float R = .6 * sc;
    float persp = 1. / (1. - p.z * .18);

    PointOut o;
    o.position = float4(p.x * R * persp + u.c.z * 2., p.y * R * persp, 0, 1);
    float limb = 1. - abs(p.z);
    float front = step(0., p.z);
    float3 c = mix(C2, C1, .5 + .5 * p.y);
    c = mix(c, C3, clamp(wv * wave, 0., 1.) * front);
    float b = (.12 + pow(limb, 4.) * 1.1 + max(wv, 0.) * wave * .9 * front) * mix(.35, 1., front);
    o.color = c * b * bright;
    o.size = pt * (1. + p.z * .5);
    return o;
}

fragment float4 pointFragment(PointOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - .5);
    float a = 1. - smoothstep(.15, .5, d);
    float3 c = in.color * a;
    return float4(c, max(c.r, max(c.g, c.b)));
}
"""#
}
```

- [ ] **Step 3: OrbView + renderer**

`Sources/ClaudeBubble/OrbView.swift`:
```swift
import AppKit
import ClaudeBubbleCore
import MetalKit

/// Must match `Uniforms` in OrbShaders.source.
struct OrbUniforms {
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>
    var c3: SIMD4<Float>
    var halo: SIMD4<Float>
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
}

final class OrbView: MTKView {
    private var renderer: OrbRenderer?

    init(frame: NSRect, animator: OrbAnimator) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        wantsLayer = true
        layer?.isOpaque = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        preferredFramesPerSecond = 60
        renderer = OrbRenderer(view: self, animator: animator)
        delegate = renderer
        if renderer == nil {
            isPaused = true
            NSLog("ClaudeBubble: Metal unavailable; orb disabled")
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    private let animator: OrbAnimator
    private let queue: MTLCommandQueue
    private let quadPipeline: MTLRenderPipelineState
    private let pointPipeline: MTLRenderPipelineState
    private let points: MTLBuffer
    private var lastTime = CACurrentMediaTime()

    init?(view: MTKView, animator: OrbAnimator) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return nil }
        let pts = OrbGeometry.fibonacciSphere()
        guard let points = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<Float>.stride) else { return nil }
        do {
            let library = try device.makeLibrary(source: OrbShaders.source, options: nil)
            func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                let ca = d.colorAttachments[0]!
                ca.pixelFormat = view.colorPixelFormat
                ca.isBlendingEnabled = true
                ca.rgbBlendOperation = .add
                ca.alphaBlendOperation = .add
                ca.sourceRGBBlendFactor = .one
                ca.destinationRGBBlendFactor = .one
                ca.sourceAlphaBlendFactor = .one
                ca.destinationAlphaBlendFactor = .one
                return try device.makeRenderPipelineState(descriptor: d)
            }
            quadPipeline = try pipeline("quadVertex", "quadFragment")
            pointPipeline = try pipeline("pointVertex", "pointFragment")
        } catch {
            NSLog("ClaudeBubble: shader setup failed: \(error)")
            return nil
        }
        self.animator = animator
        self.queue = queue
        self.points = points
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let f = animator.step(dt: now - lastTime)
        lastTime = now
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let dpr = Float(min(view.window?.backingScaleFactor ?? 2, 2))
        let pointSize = max(1, Float(view.bounds.width) / 200) * dpr * 1.6
        var u = OrbUniforms(
            c1: SIMD4(f.params.c1, 0), c2: SIMD4(f.params.c2, 0), c3: SIMD4(f.params.c3, 0), halo: SIMD4(f.params.halo, 0),
            a: [f.phase, f.scale, f.glow, f.ring],
            b: [f.params.glitch, f.params.wave, f.params.bright, pointSize],
            c: [Float(view.drawableSize.width), Float(view.drawableSize.height), f.shakeX, 0]
        )
        let len = MemoryLayout<OrbUniforms>.stride

        enc.setRenderPipelineState(quadPipeline)
        enc.setFragmentBytes(&u, length: len, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        enc.setRenderPipelineState(pointPipeline)
        enc.setVertexBytes(&u, length: len, index: 0)
        enc.setVertexBuffer(points, offset: 0, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: OrbGeometry.pointCount)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
```

- [ ] **Step 4: BubblePanel**

`Sources/ClaudeBubble/BubblePanel.swift`:
```swift
import AppKit
import ClaudeBubbleCore

/// Borderless floating panel hosting the orb; visible on every Space and drag-to-move.
final class BubblePanel: NSPanel {
    static let side: CGFloat = 120
    private static let originKey = "bubbleOrigin"
    private let orbView: OrbView

    init(animator: OrbAnimator) {
        let side = Self.side
        orbView = OrbView(frame: NSRect(x: 0, y: 0, width: side, height: side), animator: animator)
        super.init(contentRect: NSRect(origin: Self.initialOrigin(), size: NSSize(width: side, height: side)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = orbView
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setRendering(_ on: Bool) { orbView.isPaused = !on }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        setFrameOrigin(Self.initialOrigin())
    }

    @objc private func didMove() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }

    private static func initialOrigin() -> CGPoint {
        let saved = UserDefaults.standard.string(forKey: originKey).map { NSPointFromString($0) }
        let main = NSScreen.screens.first?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return BubblePlacement.origin(saved: saved, size: side, screenFrames: NSScreen.screens.map(\.frame), mainVisibleFrame: main)
    }
}
```

- [ ] **Step 5: AppDelegate + main**

`Sources/ClaudeBubble/AppDelegate.swift`:
```swift
import AppKit
import ClaudeBubbleCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let animator = OrbAnimator()
    private var panel: BubblePanel!
    private var statusItem: NSStatusItem!
    private var watcher: SessionWatcher!
    private var liveState: BubbleState = .idle
    private var forcedState: BubbleState?
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleBubble), keyEquivalent: "")
    private var debugItems: [NSMenuItem] = []

    private var bubbleHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "bubbleHidden") }
        set { UserDefaults.standard.set(newValue, forKey: "bubbleHidden") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = BubblePanel(animator: animator)
        setUpStatusItem()
        watcher = SessionWatcher(directory: SessionStore.defaultDirectory) { [weak self] state in
            self?.liveState = state
            self?.applyState()
        }
        watcher.start()
        updateVisibility()
        applyState()
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(item("Reset Position", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(item("Install Claude Code Hooks…", #selector(installHooks)))
        menu.addItem(.separator())

        let debug = NSMenu()
        for (title, key) in [("Live", "live"), ("Idle", "idle"), ("Working", "working"), ("Needs You", "needs"), ("Error", "error")] {
            let it = item(title, #selector(setDebugState(_:)))
            it.representedObject = key
            debug.addItem(it)
            debugItems.append(it)
        }
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugItem.submenu = debug
        menu.addItem(debugItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Bubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func applyState() {
        let state = forcedState ?? liveState
        animator.setState(state)
        statusItem.button?.image = Self.statusImage(for: state)
        let selected = forcedState?.rawValue ?? "live"
        for it in debugItems { it.state = (it.representedObject as? String) == selected ? .on : .off }
    }

    private func updateVisibility() {
        if bubbleHidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        panel.setRendering(!bubbleHidden)
        toggleItem.title = bubbleHidden ? "Show Bubble" : "Hide Bubble"
    }

    @objc private func toggleBubble() {
        bubbleHidden.toggle()
        updateVisibility()
    }

    @objc private func resetPosition() { panel.resetPosition() }

    @objc private func setDebugState(_ sender: NSMenuItem) {
        forcedState = (sender.representedObject as? String).flatMap(BubbleState.init(rawValue:))
        applyState()
    }

    @objc private func installHooks() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        do {
            guard let source = Bundle.main.url(forResource: "claude-bubble-hook", withExtension: "sh") else {
                throw HookInstaller.InstallError.missingHookScript
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            try HookInstaller.install(settingsURL: home.appendingPathComponent(".claude/settings.json"),
                                      hookSource: source,
                                      hookDestination: home.appendingPathComponent(".claude-bubble/hook.sh"))
            alert.messageText = "Hooks installed"
            alert.informativeText = "New Claude Code sessions will report to the bubble; restart running sessions to pick it up. Your previous settings were saved to settings.json.claude-bubble.bak."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn't install hooks"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private static func statusImage(for state: BubbleState) -> NSImage? {
        let image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Claude Bubble: \(state.rawValue)")
        let color: NSColor? = switch state {
        case .idle: nil
        case .working: .systemPurple
        case .needs: .systemOrange
        case .error: .systemRed
        }
        guard let color else {
            image?.isTemplate = true
            return image
        }
        let tinted = image?.withSymbolConfiguration(.init(paletteColors: [color]))
        tinted?.isTemplate = false
        return tinted
    }
}
```

`Sources/ClaudeBubble/main.swift` (replace contents):
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
```

- [ ] **Step 6: Bundle**

`Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Claude Bubble</string>
    <key>CFBundleDisplayName</key><string>Claude Bubble</string>
    <key>CFBundleIdentifier</key><string>com.brentmiller.ClaudeBubble</string>
    <key>CFBundleExecutable</key><string>ClaudeBubble</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
```

`scripts/bundle.sh`:
```bash
#!/bin/bash
# Builds build/ClaudeBubble.app from the SwiftPM release binary.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=build/ClaudeBubble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeBubble "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp hook/claude-bubble-hook.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/claude-bubble-hook.sh"
codesign --force --sign - "$APP"
echo "Built $APP"
```

Also create `.gitignore`:
```
.build/
build/
```

- [ ] **Step 7: Build and check**

Run: `chmod +x scripts/bundle.sh && swift test && bash tests/hook_test.sh && scripts/bundle.sh`
Expected: tests pass, then "Built build/ClaudeBubble.app".

Manual check (the user runs this, since `open` is blocked in the sandbox): `open build/ClaudeBubble.app`.
- The idle orb breathes at bottom-center.
- Debug ▸ Working / Needs You / Error each match the HTML mockup's states.
- Dragging moves the orb, and the new position survives a relaunch.
- Install Hooks… adds the entries, and a new `claude` session drives the orb live.

- [ ] **Step 8: Commit**

```bash
git add .
git commit -m "feat: Metal particle orb in floating panel with menu bar controls"
```
