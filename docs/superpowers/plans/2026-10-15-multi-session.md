# Multi-Session View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With several Claude Code sessions running, show one pip per session under the orb, and a hover list giving each session's project, status line and time in its current state.

**Architecture:**
- The hook writes richer per-session records: project, status line, time of the last state change, Claude's pid, and the tool-id correlation map.
- The core library decodes them, drops sessions whose Claude process has died, and supplies pure helpers for pips, elapsed-time text, hover timing and list placement.
- The app adds a SwiftUI pip row inside the bubble panel, plus a second floating panel with the session list. Its mini orbs are still frames rendered offscreen by the existing shaders.

**Tech Stack:**
- Swift 5.10 language mode (Swift 6.4 toolchain), Swift Package Manager, AppKit + SwiftUI (`NSHostingView`), Metal, XCTest
- bash + `/usr/bin/python3` hook

**Spec:** `docs/superpowers/specs/2026-10-15-multi-session-design.md`

## Global Constraints

- **Pips:**
  - shown only with 2+ sessions;
  - at most 6 shown, past that 5 pips plus `+N`;
  - 6pt dots, 5pt apart, sorted error > needs > working > idle, then most recent `stateSince`.
- **Hover list:**
  - opens after 300ms over the orb and closes 250ms after the pointer leaves both orb and list;
  - about 290pt wide, 14pt corner radius, background `#17161c` at 96%, 1pt border at white 8%;
  - detail color amber `#f0a050` for needs, red `#e8554f` for error, otherwise secondary.
- **`detail`:** at most 60 chars, ending in `…` when cut, always one line.
- **`ElapsedFormat`:** `0:42` under 10 min, `22m` under 1 h, `3h` under a day, `2d` beyond.
- **Liveness:**
  - `kill(pid, 0) == 0 || errno == EPERM` counts as alive, and any error other than `ESRCH` counts as alive;
  - a live pid exempts a session from the 15/60-min staleness rules and from the 24h cleanup;
  - a nil pid keeps the old rules.
- **Hook:** always exits 0 and never writes stdout. It keeps every existing behavior: the replay window, `prompted`, `pending`, and compact/resume handling.
- **Mini orbs:** rendered once at launch, 96px per state. If a render fails, fall back to a flat circle.
- **Commits:** no AI attribution lines.

## Review Focus

1. The pid the hook records could be shared by all sessions (Claude's background host) rather than belonging to one session. Every session would then look alive forever. Pinned in Task 1 Step 5, a manual check that two live sessions record different pids. The walk-past-shells logic is pinned by `hook_test.sh` "pid skips the shell".
2. `tool_input` that's a string or missing, or a missing `tool_name`: the hook must still write a sensible status line and exit 0. Pinned in Task 1, "odd tool_input still writes".
3. A long or multi-line Bash `description` must become one clipped line, not wreck the row layout. Pinned in Task 1, "long description clipped".
4. Hovering when no sessions exist, or the last session ending while the list is open: the list must not open, or must close. Pinned in Task 3, `testNoContentNeverOpens` and `testLosingContentCloses`.
5. The orb parked near the top-right or bottom of a screen: the list must stay fully on screen, flipping above or below and clamping sideways. Pinned in Task 3, `testFlipsAboveWhenNoRoomBelow` and `testClampsToTheRightEdge`.

## Rulings carried into the plan

- **Spec says the panel grows to 120×140pt. The plan keeps it at 120×120 and draws the pips in the bottom margin.** The orb's lowest edge sits 24pt above the panel bottom. Not resizing leaves `BubblePlacement`, the hit test and saved positions untouched. Cost if wrong: pips sit slightly closer to the orb glow than in the mockup.
- **The hook pid is found by walking up from the hook's parent past shell processes** (`sh`, `bash`, `zsh`, `dash`), because Claude runs hooks through a shell. `CLAUDE_BUBBLE_PID` in the environment overrides this, for tests.

---

### Task 1: Hook records project, detail, state_since, pid and tool ids

**Files:**
- Modify: `hook/claude-bubble-hook.sh`
- Test: `Tests/hook_test.sh`

**Interfaces:**
- Produces new session-file fields:
  - `project` (str)
  - `detail` (str, ≤60 chars, one line)
  - `state_since` (float epoch)
  - `pid` (int)
  - `tool_ids` (object, ≤20 entries, insertion-ordered)
- Existing fields are unchanged.

- [ ] **Step 1: Write the failing tests**

Add a `field_of` helper next to `state_of` near the top of `Tests/hook_test.sh`:
```bash
field_of() { /usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],"<none>"))' "$S/$1.json" "$2" 2>/dev/null || echo "<none>"; }
expect_field() {
  local got; got=$(field_of "$1" "$2")
  if [ "$got" = "$3" ]; then echo "ok   $4"; else echo "FAIL $4: expected '$3', got '$got'"; fail=1; fi
}
```

Insert this block immediately before the `out=$(printf 'not json'` line:
```bash
# Multi-session: project, detail, state_since, pid, tool_ids
export CLAUDE_BUBBLE_PID=4242
send '{"hook_event_name":"SessionStart","session_id":"d","cwd":"/Users/me/code/web-app"}'
expect_field d project web-app "project from cwd"
expect_field d detail Idle "SessionStart detail Idle"
expect_field d pid 4242 "pid written"
send '{"hook_event_name":"UserPromptSubmit","session_id":"d"}';  expect_field d detail Thinking "prompt detail Thinking"
since1=$(field_of d state_since)
sleep 0.05
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"npm test","description":"Running tests"}}'
expect_field d detail "Running tests" "Bash description detail"
check '[ "$(field_of d state_since)" = "$since1" ]' "state_since unchanged while still working"
send '{"hook_event_name":"PostToolUse","session_id":"d","tool_use_id":"b1"}'; expect_field d detail "Running tests" "PostToolUse keeps detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"/a/b.ts"}}'; expect_field d detail "Reading files" "Read detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Edit","tool_use_id":"e1","tool_input":{"file_path":"/repo/src/auth.ts"}}'; expect_field d detail "Editing auth.ts" "Edit detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"WebSearch","tool_use_id":"w1","tool_input":{"query":"x"}}'; expect_field d detail "Searching the web" "web detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Task","tool_use_id":"t1","tool_input":{}}'; expect_field d detail "Running subagent" "subagent detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"mcp__db__query","tool_use_id":"m1","tool_input":{}}'; expect_field d detail "Using mcp__db__query" "other tool detail"
send '{"hook_event_name":"PreToolUse","session_id":"d","tool_name":"Edit","tool_use_id":"e2","tool_input":{"file_path":"/repo/src/auth.ts","old_string":"a","new_string":"b"}}'
send '{"hook_event_name":"PermissionRequest","session_id":"d","tool_name":"Edit","tool_input":{"file_path":"/repo/src/auth.ts","old_string":"a","new_string":"b"}}'
expect d needs "permission without tool_use_id -> needs"
expect_field d detail "Approve Edit auth.ts?" "permission detail names the file"
check '[ "$(field_of d state_since)" != "$since1" ]' "state_since resets on state change"
send '{"hook_event_name":"PostToolUse","session_id":"d","tool_use_id":"other"}'; expect d needs "another tool finishing keeps needs (tool_ids correlation)"
expect_field d detail "Approve Edit auth.ts?" "needs keeps Approve detail"
send '{"hook_event_name":"PostToolUse","session_id":"d","tool_use_id":"e2"}';    expect d working "the approved tool finishing clears needs"
send '{"hook_event_name":"PermissionRequest","session_id":"d","tool_name":"Bash","tool_input":{"command":"terraform apply -auto-approve"}}'
expect_field d detail "Approve Bash terraform apply -auto-approve?" "permission detail uses command"
send '{"hook_event_name":"StopFailure","session_id":"d","error":"terraform plan failed"}'; expect_field d detail "terraform plan failed" "error detail string"
send '{"hook_event_name":"StopFailure","session_id":"d","error":{"message":"API overloaded"}}'; expect_field d detail "API overloaded" "error detail object"
send '{"hook_event_name":"StopFailure","session_id":"d"}';                       expect_field d detail "Error" "error detail fallback"
send '{"hook_event_name":"Stop","session_id":"d"}';                              expect_field d detail Idle "Stop detail Idle"
send '{"hook_event_name":"Elicitation","session_id":"d"}';                       expect_field d detail "Input requested" "elicitation detail"
send '{"hook_event_name":"SessionEnd","session_id":"d"}'

send '{"hook_event_name":"SessionStart","session_id":"e"}';                      expect_field e project session "empty cwd -> project session"
send '{"hook_event_name":"UserPromptSubmit","session_id":"e"}'
send '{"hook_event_name":"PreToolUse","session_id":"e","tool_input":"weird"}';   expect_field e detail "Working" "odd tool_input still writes"
long=$(printf 'Run the whole integration suite against staging\\nthen collect coverage and upload artifacts')
send "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"e\",\"tool_name\":\"Bash\",\"tool_use_id\":\"l1\",\"tool_input\":{\"description\":\"$long\"}}"
check '[ "$(field_of e detail)" = "Run the whole integration suite against staging then collec…" ]' "long description clipped to one 60-char line"
for i in $(seq 1 25); do send "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"e\",\"tool_name\":\"Read\",\"tool_use_id\":\"x$i\",\"tool_input\":{\"file_path\":\"/f$i\"}}"; done
check '[ "$(/usr/bin/python3 -c "import json;print(len(json.load(open(\"$S/e.json\"))[\"tool_ids\"]))")" = 20 ]' "tool_ids capped at 20"
send '{"hook_event_name":"SessionEnd","session_id":"e"}'

unset CLAUDE_BUBBLE_PID
got=$(/usr/bin/python3 - "$HOOK" "$S" <<'PY'
import json, os, subprocess, sys
hook, s = sys.argv[1], sys.argv[2]
subprocess.run(['/bin/sh', '-c', '"%s"' % hook], input=b'{"hook_event_name":"SessionStart","session_id":"w"}')
print('same' if json.load(open(os.path.join(s, 'w.json')))['pid'] == os.getpid() else 'different')
PY
)
check '[ "$got" = same ]' "pid skips the shell to reach the calling process"
send '{"hook_event_name":"SessionEnd","session_id":"w"}'
```

- [ ] **Step 2: Run to verify failure**

Run: `bash Tests/hook_test.sh | grep -E "FAIL|passed"` (outside the sandbox: `mktemp`/`ps` need it)
Expected: FAIL lines for the new checks, starting with "project from cwd: expected 'web-app', got '<none>'".

- [ ] **Step 3: Implement**

In `hook/claude-bubble-hook.sh`, replace the final line pair
```bash
/usr/bin/python3 -c "$PY" "$DIR" >/dev/null 2>&1
exit 0
```
with:
```bash
# Claude runs hooks through a shell; walk past shells to the Claude process that owns this session.
if [ -z "${CLAUDE_BUBBLE_PID:-}" ]; then
  pid=$PPID
  for _ in 1 2 3 4; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "${comm##*/}" in
      sh|bash|zsh|dash|-sh|-bash|-zsh) pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') ;;
      *) break ;;
    esac
    [ -n "$pid" ] || break
  done
  export CLAUDE_BUBBLE_PID="$pid"
fi

/usr/bin/python3 -c "$PY" "$DIR" >/dev/null 2>&1
exit 0
```

In the embedded Python, change the first line to `import hashlib, json, os, sys, tempfile, time`.

Then replace everything from `os.makedirs(d, exist_ok=True)` through the line ending `'pending': sorted(pending), 'prompted': prompted}` with:
```python
tool = str(data.get('tool_name') or '')
tin = data.get('tool_input') if isinstance(data.get('tool_input'), dict) else {}


def clip(text, n=60):
    text = ' '.join(str(text).split())
    return text if len(text) <= n else text[:n - 1] + '…'


def base(p):
    return os.path.basename(str(p).rstrip('/')) if p else ''


prev_detail = str(prev.get('detail', ''))
if event == 'StopFailure':
    err = data.get('error')
    if isinstance(err, dict):
        err = err.get('message', '')
    detail = clip(err) if err else 'Error'
elif state == 'error':
    detail = prev_detail or 'Error'
elif state == 'needs':
    if event == 'PermissionRequest':
        target = base(tin.get('file_path') or tin.get('notebook_path')) or clip(tin.get('command', ''), 40)
        detail = clip(f'Approve {tool} {target}?' if target else f'Approve {tool}?')
    elif event == 'Elicitation' or ntype in ('elicitation_dialog', 'elicitation_url_dialog'):
        detail = 'Input requested'
    else:
        detail = prev_detail if prev_detail.startswith('Approve') else 'Needs you'
elif state == 'working':
    if event == 'PreToolUse':
        if tool == 'Bash' and tin.get('description'):
            detail = clip(tin['description'])
        elif tool in ('Read', 'Grep', 'Glob'):
            detail = 'Reading files'
        elif tool in ('Edit', 'Write', 'NotebookEdit'):
            name = base(tin.get('file_path') or tin.get('notebook_path'))
            detail = clip(f'Editing {name}') if name else 'Editing files'
        elif tool in ('WebFetch', 'WebSearch'):
            detail = 'Searching the web'
        elif tool in ('Task', 'Agent'):
            detail = 'Running subagent'
        else:
            detail = clip(f'Using {tool}') if tool else 'Working'
    elif event == 'UserPromptSubmit':
        detail = 'Thinking'
    else:
        detail = prev_detail or 'Working'
else:
    detail = 'Idle'

cwd = data.get('cwd') or prev.get('cwd', '')
project = base(cwd) or 'session'
state_since = float(prev.get('state_since', now)) if prev.get('state') == state else now
try:
    pid = int(os.environ.get('CLAUDE_BUBBLE_PID', '0'))
except ValueError:
    pid = 0

os.makedirs(d, exist_ok=True)
record = {'state': state, 'event': event, 'cwd': cwd, 'updated_at': now, 'started_at': started,
          'pending': sorted(pending), 'prompted': prompted, 'project': project, 'detail': detail,
          'state_since': state_since, 'pid': pid, 'tool_ids': tool_ids}
```

Next, add the tool-id correlation. Replace the existing line
```python
tool_id = data.get('tool_use_id') or '?'
```
with:
```python
def tool_key(payload):
    raw = str(payload.get('tool_name') or '') + json.dumps(payload.get('tool_input'), sort_keys=True, default=str)
    return hashlib.sha1(raw.encode()).hexdigest()[:12]


# PermissionRequest carries no tool_use_id, but the PreToolUse for the same call does.
tool_ids = dict(prev.get('tool_ids', {}))
if event == 'PreToolUse' and data.get('tool_use_id'):
    key = tool_key(data)
    tool_ids.pop(key, None)
    tool_ids[key] = data['tool_use_id']
    while len(tool_ids) > 20:
        tool_ids.pop(next(iter(tool_ids)))
tool_id = data.get('tool_use_id') or (tool_ids.get(tool_key(data)) if event == 'PermissionRequest' else None) or '?'
```

- [ ] **Step 4: Run to verify pass**

Run: `bash Tests/hook_test.sh | grep -E "FAIL|passed"` and `bash Tests/hook_test.sh | grep -c '^ok'`
Expected: "all hook tests passed". Every earlier check still passes.

- [ ] **Step 5: Manual pid check (Review Focus 1)**

1. Install the updated hook: `cp hook/claude-bubble-hook.sh ~/.claude-bubble/hook.sh`.
2. Send one prompt from two separate live `claude` sessions.
3. Run: `/usr/bin/python3 -c 'import json,glob;[print(json.load(open(f)).get("pid"), f) for f in glob.glob("~/.claude-bubble/sessions/*.json")]'`

Expected: the two live sessions show **different** pids, and `ps -p <pid> -o comm=` names a `claude` process. If they share a pid, ledger it, set the hook to write `pid: 0` (which disables liveness), and report it to the user.

- [ ] **Step 6: Commit**

```bash
git add hook Tests/hook_test.sh
git commit -m "feat: hook records project, status line, state age, pid and tool ids"
```

---

### Task 2: Core sessions carry the new fields and liveness

**Files:**
- Modify: `Sources/ClaudeBubbleCore/SessionStore.swift`
- Test: `Tests/ClaudeBubbleCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: the Task 1 file fields.
- Produces:
  - `Session(id:state:cwd:updatedAt:project:detail:stateSince:pid:)`. The last four parameters default to `nil`, `""`, `nil` and `nil`. When `nil`, `project` comes from `cwd` (or is `"session"`) and `stateSince` equals `updatedAt`.
  - `Session` properties `project: String`, `detail: String`, `stateSince: Date`, `pid: Int32?`
  - `SessionStore.load(from: URL, now: Date = Date(), isAlive: (Int32) -> Bool = SessionStore.processIsAlive) -> [Session]`
  - `SessionStore.live(_: [Session], now: Date = Date()) -> [Session]`
  - `SessionStore.sorted(_: [Session]) -> [Session]`
  - `SessionStore.processIsAlive(_: Int32) -> Bool`
  - `aggregate` keeps its signature.

- [ ] **Step 1: Write the failing tests**

Append to `SessionStoreTests` (before the final `}`):
```swift
    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testOlderFilesDecodeWithDefaults() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"state":"idle","cwd":"/code/api-server","updated_at":\#(now.timeIntervalSince1970)}"#
            .write(to: dir.appendingPathComponent("old.json"), atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(SessionStore.load(from: dir, now: now).first)
        XCTAssertEqual(s.project, "api-server")
        XCTAssertEqual(s.detail, "")
        XCTAssertEqual(s.stateSince, now)
        XCTAssertNil(s.pid)
    }

    func testReadsNewFields() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = now.timeIntervalSince1970
        try #"{"state":"needs","cwd":"/x","updated_at":\#(t),"project":"web-app","detail":"Approve Edit auth.ts?","state_since":\#(t - 42),"pid":777}"#
            .write(to: dir.appendingPathComponent("n.json"), atomically: true, encoding: .utf8)
        let s = try XCTUnwrap(SessionStore.load(from: dir, now: now, isAlive: { _ in true }).first)
        XCTAssertEqual(s.project, "web-app")
        XCTAssertEqual(s.detail, "Approve Edit auth.ts?")
        XCTAssertEqual(s.stateSince, now.addingTimeInterval(-42))
        XCTAssertEqual(s.pid, 777)
    }

    func testDeadPidIsDroppedAndDeleted() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dead.json")
        try #"{"state":"working","updated_at":\#(now.timeIntervalSince1970),"pid":999}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStore.load(from: dir, now: now, isAlive: { _ in false }), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testLivePidSurvivesTheDayOldCleanup() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"{"state":"idle","updated_at":\#(now.timeIntervalSince1970 - 25 * 3600),"pid":5}"#
            .write(to: dir.appendingPathComponent("idle.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(SessionStore.load(from: dir, now: now, isAlive: { _ in true }).count, 1)
    }

    func testLivePidIsExemptFromStaleness() {
        let s = Session(id: "a", state: .working, updatedAt: now.addingTimeInterval(-2 * 3600), pid: 5)
        XCTAssertEqual(SessionStore.live([s], now: now), [s])
        XCTAssertEqual(SessionStore.aggregate([s], now: now), .working)
    }

    func testSortedByUrgencyThenMostRecentChange() {
        let idle = Session(id: "i", state: .idle, updatedAt: now)
        let oldWork = Session(id: "w1", state: .working, updatedAt: now, stateSince: now.addingTimeInterval(-300))
        let newWork = Session(id: "w2", state: .working, updatedAt: now, stateSince: now.addingTimeInterval(-10))
        let needs = Session(id: "n", state: .needs, updatedAt: now)
        let error = Session(id: "e", state: .error, updatedAt: now)
        XCTAssertEqual(SessionStore.sorted([idle, oldWork, needs, newWork, error]).map(\.id), ["e", "n", "w2", "w1", "i"])
    }

    func testProcessIsAliveForThisProcessOnly() {
        XCTAssertTrue(SessionStore.processIsAlive(getpid()))
        XCTAssertFalse(SessionStore.processIsAlive(99_999_999))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionStoreTests`
Expected: compile failure "extra argument 'pid' in call" / "value of type 'Session' has no member 'project'".

- [ ] **Step 3: Implement**

Replace `Sources/ClaudeBubbleCore/SessionStore.swift` with:
```swift
import Foundation

public struct Session: Equatable, Sendable {
    public let id: String
    public let state: BubbleState
    public let cwd: String
    public let updatedAt: Date
    public let project: String
    public let detail: String
    public let stateSince: Date
    /// The Claude process that owns this session; nil for files written by an older hook.
    public let pid: Int32?

    public init(id: String, state: BubbleState, cwd: String = "", updatedAt: Date,
                project: String? = nil, detail: String = "", stateSince: Date? = nil, pid: Int32? = nil) {
        self.id = id
        self.state = state
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.project = project ?? Session.projectName(for: cwd)
        self.detail = detail
        self.stateSince = stateSince ?? updatedAt
        self.pid = pid
    }

    static func projectName(for cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "session" : name
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
        let project: String?
        let detail: String?
        let state_since: Double?
        let pid: Int32?
    }

    /// True unless the kernel says the process is gone; a permission error still means it exists.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    public static func load(from dir: URL, now: Date = Date(), isAlive: (Int32) -> Bool = processIsAlive) -> [Session] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sessions: [Session] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  let state = BubbleState(rawValue: record.state) else { continue }
            let updated = Date(timeIntervalSince1970: record.updated_at)
            // pid 0/1 would make kill() target a process group or launchd, so treat it as unknown.
            let pid = record.pid.flatMap { $0 > 1 ? $0 : nil }
            if let pid, !isAlive(pid) {
                try? fm.removeItem(at: url)
                continue
            }
            if pid == nil, now.timeIntervalSince(updated) > deleteAfter {
                try? fm.removeItem(at: url)
                continue
            }
            sessions.append(Session(id: String(name.dropLast(5)), state: state, cwd: record.cwd ?? "", updatedAt: updated,
                                    project: record.project, detail: record.detail ?? "",
                                    stateSince: record.state_since.map(Date.init(timeIntervalSince1970:)), pid: pid))
        }
        return sessions
    }

    /// Sessions worth showing: a live process always counts; without a pid, fall back to staleness.
    public static func live(_ sessions: [Session], now: Date = Date()) -> [Session] {
        sessions.filter { s in
            s.pid != nil || now.timeIntervalSince(s.updatedAt) <= (s.state == .needs ? needsStaleAfter : staleAfter)
        }
    }

    public static func aggregate(_ sessions: [Session], now: Date = Date()) -> BubbleState {
        live(sessions, now: now).map(\.state).max { $0.priority < $1.priority } ?? .idle
    }

    /// Most urgent first; within a state, the most recent change first.
    public static func sorted(_ sessions: [Session]) -> [Session] {
        sessions.sorted { a, b in
            a.state.priority != b.state.priority ? a.state.priority > b.state.priority : a.stateSince > b.stateSince
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: all tests pass (37 earlier + 7 new = 44).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeBubbleCore/SessionStore.swift Tests/ClaudeBubbleCoreTests/SessionStoreTests.swift
git commit -m "feat: sessions carry project, status, state age and pid liveness"
```

---

### Task 3: Pure helpers for pips, elapsed time, hover timing, list placement

**Files:**
- Create: `Sources/ClaudeBubbleCore/SessionPresentation.swift`
- Test: `Tests/ClaudeBubbleCoreTests/SessionPresentationTests.swift`

**Interfaces:**
- Consumes: `Session`, `SessionStore.sorted`.
- Produces:
  - `PipLayout.pips(for: [Session], max: Int = 6) -> PipLayout.Result`, where `Result` has `states: [BubbleState]` and `overflow: Int` and is Equatable
  - `ElapsedFormat.string(_: TimeInterval) -> String`
  - `HoverTracker` (struct): `openDelay = 0.3`, `closeDelay = 0.25`, `isOpen: Bool`, and `mutating update(overOrb: Bool, overList: Bool, hasContent: Bool, now: Double) -> Bool`
  - `SessionListPlacement.orbRect(panelFrame: CGRect) -> CGRect` and `SessionListPlacement.frame(listSize: CGSize, orbRect: CGRect, visibleFrame: CGRect) -> CGRect`

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeBubbleCoreTests/SessionPresentationTests.swift`:
```swift
import XCTest
@testable import ClaudeBubbleCore

final class SessionPresentationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func sessions(_ states: [BubbleState]) -> [Session] {
        states.enumerated().map { Session(id: "\($0.offset)", state: $0.element, updatedAt: now) }
    }

    // PipLayout
    func testNoPipsForZeroOrOneSession() {
        XCTAssertEqual(PipLayout.pips(for: []), .init(states: [], overflow: 0))
        XCTAssertEqual(PipLayout.pips(for: sessions([.working])), .init(states: [], overflow: 0))
    }

    func testOnePipPerSessionSortedByUrgency() {
        XCTAssertEqual(PipLayout.pips(for: sessions([.idle, .needs])), .init(states: [.needs, .idle], overflow: 0))
        XCTAssertEqual(PipLayout.pips(for: sessions([.idle, .working, .error, .needs, .idle, .working])),
                       .init(states: [.error, .needs, .working, .working, .idle, .idle], overflow: 0))
    }

    func testCollapsesPastSix() {
        let nine = sessions([.idle, .idle, .idle, .working, .working, .needs, .error, .idle, .idle])
        XCTAssertEqual(PipLayout.pips(for: nine), .init(states: [.error, .needs, .working, .working, .idle], overflow: 4))
    }

    // ElapsedFormat
    func testElapsedFormats() {
        XCTAssertEqual(ElapsedFormat.string(-5), "0:00")
        XCTAssertEqual(ElapsedFormat.string(42), "0:42")
        XCTAssertEqual(ElapsedFormat.string(190), "3:10")
        XCTAssertEqual(ElapsedFormat.string(599), "9:59")
        XCTAssertEqual(ElapsedFormat.string(600), "10m")
        XCTAssertEqual(ElapsedFormat.string(22 * 60 + 30), "22m")
        XCTAssertEqual(ElapsedFormat.string(3600), "1h")
        XCTAssertEqual(ElapsedFormat.string(3 * 3600 + 59 * 60), "3h")
        XCTAssertEqual(ElapsedFormat.string(86400 * 2 + 5), "2d")
    }

    // HoverTracker
    func testOpensOnlyAfterTheDelay() {
        var h = HoverTracker()
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0.29))
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.31))
    }

    func testPassingOverDoesNotOpen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: false, overList: false, hasContent: true, now: 0.1)
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: true, now: 0.35))
    }

    func testMovingIntoTheListKeepsItOpen() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0.4)
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: 1.0))
        XCTAssertTrue(h.update(overOrb: false, overList: true, hasContent: true, now: 5.0))
    }

    func testClosesAfterLeavingBoth() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0.4)
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: 0.5))
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.6))   // came back in time
        XCTAssertTrue(h.update(overOrb: false, overList: false, hasContent: true, now: 0.7))
        XCTAssertFalse(h.update(overOrb: false, overList: false, hasContent: true, now: 0.96))
    }

    func testNoContentNeverOpens() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: false, now: 0)
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: false, now: 1))
    }

    func testLosingContentCloses() {
        var h = HoverTracker()
        _ = h.update(overOrb: true, overList: false, hasContent: true, now: 0)
        XCTAssertTrue(h.update(overOrb: true, overList: false, hasContent: true, now: 0.4))
        XCTAssertFalse(h.update(overOrb: true, overList: false, hasContent: false, now: 0.5))
    }

    // SessionListPlacement
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
    let size = CGSize(width: 290, height: 200)

    func testOrbRectIsTheCentralSixtyPercent() {
        XCTAssertEqual(SessionListPlacement.orbRect(panelFrame: CGRect(x: 100, y: 100, width: 120, height: 120)),
                       CGRect(x: 124, y: 124, width: 72, height: 72))
    }

    func testBelowAndCentredWhenThereIsRoom() {
        let orb = CGRect(x: 684, y: 600, width: 72, height: 72)
        XCTAssertEqual(SessionListPlacement.frame(listSize: size, orbRect: orb, visibleFrame: visible),
                       CGRect(x: 575, y: 392, width: 290, height: 200))
    }

    func testFlipsAboveWhenNoRoomBelow() {
        let orb = CGRect(x: 684, y: 150, width: 72, height: 72)
        XCTAssertEqual(SessionListPlacement.frame(listSize: size, orbRect: orb, visibleFrame: visible).minY, 230)
    }

    func testClampsToTheRightEdge() {
        let orb = CGRect(x: 1400, y: 600, width: 72, height: 72)
        XCTAssertEqual(SessionListPlacement.frame(listSize: size, orbRect: orb, visibleFrame: visible).maxX, 1432)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SessionPresentationTests`
Expected: compile failure "cannot find 'PipLayout' in scope".

- [ ] **Step 3: Implement**

`Sources/ClaudeBubbleCore/SessionPresentation.swift`:
```swift
import CoreGraphics
import Foundation

public enum PipLayout {
    public struct Result: Equatable, Sendable {
        public let states: [BubbleState]
        public let overflow: Int
        public init(states: [BubbleState], overflow: Int) {
            self.states = states
            self.overflow = overflow
        }
    }

    /// One pip per session, most urgent first; a single session needs no pips.
    public static func pips(for sessions: [Session], max: Int = 6) -> Result {
        guard sessions.count >= 2 else { return Result(states: [], overflow: 0) }
        let states = SessionStore.sorted(sessions).map(\.state)
        guard states.count > max else { return Result(states: states, overflow: 0) }
        return Result(states: Array(states.prefix(max - 1)), overflow: states.count - (max - 1))
    }
}

public enum ElapsedFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let s = Int(Swift.max(0, seconds))
        switch s {
        case ..<600: return String(format: "%d:%02d", s / 60, s % 60)
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }
}

/// Open after resting on the orb, stay open while over orb or list, close shortly after leaving both.
public struct HoverTracker {
    public static let openDelay: Double = 0.3
    public static let closeDelay: Double = 0.25

    public private(set) var isOpen = false
    private var insideSince: Double?
    private var outsideSince: Double?

    public init() {}

    public mutating func update(overOrb: Bool, overList: Bool, hasContent: Bool, now: Double) -> Bool {
        guard hasContent else {
            isOpen = false
            insideSince = nil
            outsideSince = nil
            return false
        }
        let inside = overOrb || (isOpen && overList)
        if inside {
            outsideSince = nil
            let since = insideSince ?? now
            insideSince = since
            if !isOpen, now - since >= Self.openDelay { isOpen = true }
        } else {
            insideSince = nil
            if isOpen {
                let since = outsideSince ?? now
                outsideSince = since
                if now - since >= Self.closeDelay {
                    isOpen = false
                    outsideSince = nil
                }
            }
        }
        return isOpen
    }
}

public enum SessionListPlacement {
    public static let gap: CGFloat = 8
    public static let margin: CGFloat = 8

    /// The orb fills the central 60% of the bubble panel.
    public static func orbRect(panelFrame: CGRect) -> CGRect {
        panelFrame.insetBy(dx: panelFrame.width * 0.2, dy: panelFrame.height * 0.2)
    }

    /// Below the orb when it fits, otherwise above; centred on the orb and kept inside the screen.
    public static func frame(listSize: CGSize, orbRect: CGRect, visibleFrame: CGRect) -> CGRect {
        let centred = orbRect.midX - listSize.width / 2
        let x = Swift.min(Swift.max(centred, visibleFrame.minX + margin), visibleFrame.maxX - listSize.width - margin)
        let below = orbRect.minY - gap - listSize.height
        let y = below >= visibleFrame.minY + margin ? below : orbRect.maxY + gap
        return CGRect(x: x, y: y, width: listSize.width, height: listSize.height)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: all pass (44 + 13 = 57).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeBubbleCore/SessionPresentation.swift Tests/ClaudeBubbleCoreTests/SessionPresentationTests.swift
git commit -m "feat: pip layout, elapsed format, hover timing and list placement"
```

---

### Task 4: Pips, hover list and mini orbs in the app

**Files:**
- Modify: `Sources/ClaudeBubbleCore/SessionWatcher.swift`
- Modify: `Sources/ClaudeBubble/OrbShaders.swift` (gains `OrbUniforms`)
- Modify: `Sources/ClaudeBubble/OrbView.swift` (loses `OrbUniforms`)
- Create: `Sources/ClaudeBubble/OrbSnapshot.swift`
- Create: `Sources/ClaudeBubble/SessionsModel.swift`
- Create: `Sources/ClaudeBubble/SessionViews.swift`
- Create: `Sources/ClaudeBubble/SessionListPanel.swift`
- Modify: `Sources/ClaudeBubble/BubblePanel.swift`
- Modify: `Sources/ClaudeBubble/AppDelegate.swift`
- Modify: `scripts/icon/main.swift`, `scripts/make-icon.sh`

**Interfaces:**
- Consumes: Tasks 2–3 (`SessionStore.live`, `SessionStore.sorted`, `PipLayout`, `ElapsedFormat`, `HoverTracker`, `SessionListPlacement`, `BubblePlacement.isOverOrb`).
- Produces:
  - `SessionWatcher(directory:onChange: (BubbleState, [Session]) -> Void)`
  - `OrbSnapshot.render(state:size:) -> CGImage?`
  - `BubblePanel(animator:model:)`
  - `SessionListPanel(model:snapshots:onSelect:)` with `show(near bubbleFrame: CGRect)`

- [ ] **Step 1: SessionWatcher publishes live sessions**

In `Sources/ClaudeBubbleCore/SessionWatcher.swift`:
- Change `private let onChange: (BubbleState) -> Void` to `private let onChange: (BubbleState, [Session]) -> Void`.
- Change the init parameter to match: `public init(directory: URL, onChange: @escaping (BubbleState, [Session]) -> Void)`.
- Add `private var lastSessions: [Session]?` below `private var last: BubbleState?`.
- Replace `refresh()` with:
```swift
    public func refresh() {
        let now = Date()
        let sessions = SessionStore.live(SessionStore.load(from: directory, now: now), now: now)
        let state = SessionStore.aggregate(sessions, now: now)
        if state != last || sessions != lastSessions {
            last = state
            lastSessions = sessions
            onChange(state, sessions)
        }
    }
```
Also make the timer survive menu tracking: replace the `timer = Timer.scheduledTimer(...)` line with
```swift
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
```

- [ ] **Step 2: Shared offscreen orb renderer**

Move `struct OrbUniforms { ... }` (with its doc comment) out of `Sources/ClaudeBubble/OrbView.swift` and append it unchanged to `Sources/ClaudeBubble/OrbShaders.swift`, after the `enum OrbShaders` closing brace.

`Sources/ClaudeBubble/OrbSnapshot.swift`:
```swift
import ClaudeBubbleCore
import CoreGraphics
import Metal

/// Still frame of the orb rendered offscreen with the live shaders; used for list mini orbs and the app icon.
enum OrbSnapshot {
    static func render(state: BubbleState, size: Int) -> CGImage? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: OrbShaders.source, options: nil) else { return nil }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            guard let ca = d.colorAttachments[0] else { return nil }
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let pts = OrbGeometry.fibonacciSphere()
        guard let quad = pipeline("quadVertex", "quadFragment"),
              let dots = pipeline("pointVertex", "pointFragment"),
              let points = device.makeBuffer(bytes: pts, length: pts.count * MemoryLayout<Float>.stride) else { return nil }

        // Let the wave settle into a pleasing frame.
        let animator = OrbAnimator(state: state, random: { 0.35 })
        var f = animator.step(dt: 0.016)
        for _ in 0..<90 { f = animator.step(dt: 0.016) }

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        td.usage = .renderTarget
        td.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: td) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        var u = OrbUniforms(
            c1: SIMD4(f.params.c1, 0), c2: SIMD4(f.params.c2, 0), c3: SIMD4(f.params.c3, 0), halo: SIMD4(f.params.halo, 0),
            a: [f.phase, f.scale, f.glow, f.ring],
            b: [f.params.glitch, f.params.wave, f.params.bright, max(1, Float(size) / 400) * 3.2],
            c: [Float(size), Float(size), 0, 0]
        )
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let len = MemoryLayout<OrbUniforms>.stride
        enc.setRenderPipelineState(quad)
        enc.setFragmentBytes(&u, length: len, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.setRenderPipelineState(dots)
        enc.setVertexBytes(&u, length: len, index: 0)
        enc.setVertexBuffer(points, offset: 0, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: OrbGeometry.pointCount)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: size * size * 4)
        texture.getBytes(&px, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return px.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?
                .makeImage()
        }
    }
}
```

Replace the whole `func renderOrb(size: Int) -> CGImage { ... }` function and the `struct Uniforms` line in `scripts/icon/main.swift` with nothing. Then change the draw call to:
```swift
ctx.draw(OrbSnapshot.render(state: .working, size: 1000)!, in: CGRect(x: 12, y: 12, width: 1000, height: 1000))
```
Remove `import Metal` from `scripts/icon/main.swift`.

In `scripts/make-icon.sh`, replace the line that builds `lib.swift` with:
```bash
{ echo "import CoreGraphics"; echo "import Foundation"; echo "import Metal"; cat Sources/ClaudeBubble/{OrbShaders,OrbSnapshot}.swift Sources/ClaudeBubbleCore/{BubbleState,OrbParams,OrbAnimator,OrbGeometry}.swift | grep -vE '^import (Foundation|Metal|ClaudeBubbleCore|CoreGraphics)$'; } > "$WORK/lib.swift"
```

- [ ] **Step 3: Model, pips and list views**

`Sources/ClaudeBubble/SessionsModel.swift`:
```swift
import ClaudeBubbleCore
import Combine

/// Live sessions shared by the pips and the hover list.
final class SessionsModel: ObservableObject {
    @Published var sessions: [Session] = []
}
```

`Sources/ClaudeBubble/SessionViews.swift`:
```swift
import AppKit
import ClaudeBubbleCore
import SwiftUI

extension BubbleState {
    /// The state's main orb color, for pips and fallbacks.
    var accent: Color {
        let c = OrbParams.target(for: self).c1
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    var detailColor: Color {
        switch self {
        case .needs: Color(red: 0xf0 / 255, green: 0xa0 / 255, blue: 0x50 / 255)
        case .error: Color(red: 0xe8 / 255, green: 0x55 / 255, blue: 0x4f / 255)
        case .idle, .working: Color.white.opacity(0.55)
        }
    }
}

struct PipsView: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        let layout = PipLayout.pips(for: model.sessions)
        HStack(spacing: 5) {
            ForEach(Array(layout.states.enumerated()), id: \.offset) { _, state in
                Circle()
                    .fill(state.accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: state.accent.opacity(0.8), radius: 3)
            }
            if layout.overflow > 0 {
                Text("+\(layout.overflow)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: layout)
    }
}

struct SessionRow: View {
    let session: Session
    let now: Date
    let snapshot: NSImage?
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable().frame(width: 40, height: 40)
                } else {
                    Circle().fill(session.state.accent).frame(width: 18, height: 18)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                Text(session.detail.isEmpty ? "Idle" : session.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(session.state.detailColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ElapsedFormat.string(now.timeIntervalSince(session.stateSince)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(highlighted ? 0.06 : 0)))
        .contentShape(Rectangle())
    }
}

struct SessionListView: View {
    @ObservedObject var model: SessionsModel
    let snapshots: [BubbleState: NSImage]
    let onSelect: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 2) {
                ForEach(Array(SessionStore.sorted(model.sessions).enumerated()), id: \.element.id) { index, session in
                    SessionRow(session: session, now: context.date, snapshot: snapshots[session.state], highlighted: index == 0)
                        .onTapGesture(perform: onSelect)
                }
            }
            .padding(8)
        }
        .frame(width: 290)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0x17 / 255, green: 0x16 / 255, blue: 0x1c / 255).opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// Hosting view that clicks fall straight through, for decoration drawn over the orb.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hosting view that takes the first click even though its panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
```

- [ ] **Step 4: List panel**

`Sources/ClaudeBubble/SessionListPanel.swift`:
```swift
import AppKit
import ClaudeBubbleCore
import Combine
import SwiftUI

/// Floating session list shown while hovering the orb.
final class SessionListPanel: NSPanel {
    private let host: FirstMouseHostingView<SessionListView>
    private var bubbleFrame: CGRect = .zero
    private var subscription: AnyCancellable?

    init(model: SessionsModel, snapshots: [BubbleState: NSImage], onSelect: @escaping () -> Void) {
        host = FirstMouseHostingView(rootView: SessionListView(model: model, snapshots: snapshots, onSelect: onSelect))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        contentView = host
        // Rows come and go while the list is open; refit and re-anchor.
        subscription = model.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.show(near: self.bubbleFrame)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(near bubbleFrame: CGRect) {
        self.bubbleFrame = bubbleFrame
        host.layoutSubtreeIfNeeded()
        let center = CGPoint(x: bubbleFrame.midX, y: bubbleFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? bubbleFrame.insetBy(dx: -1000, dy: -1000)
        let frame = SessionListPlacement.frame(listSize: host.fittingSize,
                                               orbRect: SessionListPlacement.orbRect(panelFrame: bubbleFrame),
                                               visibleFrame: visible)
        setFrame(frame, display: true)
        if !isVisible { orderFrontRegardless() }
    }
}
```

- [ ] **Step 5: Bubble panel hosts the pips**

In `Sources/ClaudeBubble/BubblePanel.swift`:
- Change `init(animator: OrbAnimator) {` to `init(animator: OrbAnimator, model: SessionsModel) {`.
- Replace the line `contentView = orbView` with:
```swift
        // Pips sit in the bottom margin below the orb (the orb's lowest edge is 24pt up); clicks pass through them.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        orbView.autoresizingMask = [.width, .height]
        container.addSubview(orbView)
        let pips = PassthroughHostingView(rootView: PipsView(model: model))
        pips.frame = NSRect(x: 0, y: 4, width: side, height: 14)
        container.addSubview(pips)
        contentView = container
```

- [ ] **Step 6: Wire up AppDelegate**

In `Sources/ClaudeBubble/AppDelegate.swift`, add these properties below `private var watcher: SessionWatcher!`:
```swift
    private let model = SessionsModel()
    private var listPanel: SessionListPanel!
    private var hover = HoverTracker()
    private var hoverTimer: Timer?
```

Replace this block in `applicationDidFinishLaunching`:
```swift
        panel = BubblePanel(animator: animator)
        panel.onClick = { [weak self] in self?.focusTerminal() }
```
with:
```swift
        panel = BubblePanel(animator: animator, model: model)
        panel.onClick = { [weak self] in self?.focusTerminal() }
        listPanel = SessionListPanel(model: model, snapshots: Self.renderSnapshots()) { [weak self] in
            self?.focusTerminal()
            self?.listPanel.orderOut(nil)
        }
        startHoverTracking()
```

Replace the watcher closure with:
```swift
        watcher = SessionWatcher(directory: SessionStore.defaultDirectory) { [weak self] state, sessions in
            self?.liveState = state
            self?.model.sessions = sessions
            self?.applyState()
        }
```

Add these methods after `refreshInstalledHook()`:
```swift
    private static func renderSnapshots() -> [BubbleState: NSImage] {
        var images: [BubbleState: NSImage] = [:]
        for state in BubbleState.allCases {
            if let image = OrbSnapshot.render(state: state, size: 96) {
                images[state] = NSImage(cgImage: image, size: NSSize(width: 48, height: 48))
            }
        }
        return images
    }

    /// Polls the pointer at 20Hz; cheap, and catches hovers the click-through monitors don't see.
    private func startHoverTracking() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.updateHover() }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        let open = hover.update(overOrb: !bubbleHidden && BubblePlacement.isOverOrb(mouse, panelFrame: panel.frame),
                                overList: listPanel.isVisible && listPanel.frame.contains(mouse),
                                hasContent: !bubbleHidden && !model.sessions.isEmpty,
                                now: CACurrentMediaTime())
        if open, !listPanel.isVisible {
            listPanel.show(near: panel.frame)
        } else if !open, listPanel.isVisible {
            listPanel.orderOut(nil)
        }
    }
```

- [ ] **Step 7: Build, test, bundle**

Run (outside the sandbox): `swift test 2>&1 | grep -E "error:|warning:|Executed [0-9]+ tests" | sort -u | tail -3 && bash Tests/hook_test.sh | tail -1 && scripts/bundle.sh 2>&1 | grep -E "error|warning|Installed"`
Expected: 57 tests pass, "all hook tests passed", "Installed …/Claude Bubble.app", and no warnings.

Run: `scripts/make-icon.sh && git diff --stat Resources/AppIcon.icns`
Expected: "Wrote Resources/AppIcon.icns". The icon renders the same as before; a byte-level diff is acceptable, but view the PNG to confirm it looks unchanged.

- [ ] **Step 8: Hand check (the user, after Restart)**

- With 2+ sessions open, pips appear under the orb in urgency order. With 1 session there are none.
- Resting on the orb for about 0.3s opens the list: mini orbs, project names, status lines and ticking timers.
- Moving into the list keeps it open. Leaving both closes it.
- Clicking a row focuses Hyper and closes the list.
- With the orb parked at the bottom of the screen, the list opens above it. Near the right edge, it stays on screen.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: session pips and hover list with mini orbs"
```
