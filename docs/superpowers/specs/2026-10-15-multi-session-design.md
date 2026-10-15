# Claude Bubble — Multi-Session View

Date: 2026-10-15
Builds on: `2026-10-15-claude-bubble-design.md`

## Goal

When several Claude Code sessions run at once, show at a glance how many there are and what state each is in. Hovering gives detail per session: which project it is, what it's doing, and for how long.

Success:
- With 2+ sessions, the pips under the orb show the count and mix of states without hovering.
- Hovering the orb shows a list that answers "which session needs me, and why?" in one look.

## Scope

- **In:**
  - richer per-session hook data
  - pid-based liveness
  - pips under the orb
  - hover list panel with static mini orbs and live timers
  - the `tool_use_id` correlation fix for pending permissions
- **Out:**
  - focusing a specific terminal tab (a row click focuses the terminal app, the same as the orb)
  - animated mini orbs
  - actions in the list (approve, dismiss)
  - grouping or renaming sessions

## Hook: new fields

Each session file gains:

| Field | Value |
|---|---|
| `project` | `basename(cwd)`, or `"session"` when `cwd` is empty |
| `detail` | short status line (rules below), at most 60 chars, ending in `…` when cut |
| `state_since` | epoch seconds when `state` last changed. Unchanged when an event leaves the state the same. |
| `pid` | `os.getppid()` of the hook, i.e. the Claude process for that session |
| `tool_ids` | map of `sha1(tool_name + json(tool_input, sort_keys))[:12]` to `tool_use_id`, filled on `PreToolUse` and limited to the 20 most recent |

### Detail rules (first match wins)

1. `StopFailure`: the `error` field. If it's an object, use its `message`, otherwise `str()`. If empty, use `"Error"`.
2. Final state `needs`:
   - from `PermissionRequest`: `Approve <tool_name> <target>?`, where `<target>` is the basename of `tool_input.file_path` or `notebook_path`, else the first 40 chars of `tool_input.command`, else nothing (giving `Approve <tool_name>?`);
   - from `Elicitation` or an elicitation notification: `"Input requested"`;
   - otherwise: keep the previous `detail` if it starts with `Approve`, else `"Needs you"`.
3. Final state `working`:
   - from `PreToolUse` with `tool_name == "Bash"` and `tool_input.description`: that description;
   - from `PreToolUse` otherwise: a friendly name for the tool:

     | Tool | Detail |
     |---|---|
     | Read / Grep / Glob | `Reading files` |
     | Edit / Write / NotebookEdit | `Editing <file basename>` |
     | WebFetch / WebSearch | `Searching the web` |
     | Task / Agent | `Running subagent` |
     | anything else | `Using <tool_name>` |
   - from `UserPromptSubmit`: `"Thinking"`;
   - from other events (`PostToolUse` and so on): keep the previous `detail`.
4. Final state `idle`: `"Idle"`.

### Pending-permission correlation fix

`PermissionRequest` carries no `tool_use_id` in Claude Code 2.1.300, but `PreToolUse` does, and `PreToolUse` fires first for the same call.
- On `PermissionRequest`, look up `tool_ids[hash(tool_name, tool_input)]` and use that id. Fall back to `'?'` if it isn't found.
- Post-tool events discard their own `tool_use_id`, as before.

## Core: SessionStore

- `Session` gains `project: String`, `detail: String`, `stateSince: Date`, `pid: Int32?`.
- Older files without the new fields decode with defaults: `project` comes from `cwd`, `detail` is empty, `stateSince` is `updated_at`, and `pid` is nil.
- **Liveness:** `load` takes an injectable `isAlive: (Int32) -> Bool`. In the app this is `kill(pid, 0) == 0 || errno == EPERM`.
  - A session whose pid is dead is dropped and its file deleted.
  - Sessions with `pid == nil` (written by an old hook) fall back to the existing 15/60-minute staleness rules.
  - A **live** pid exempts the session from those staleness rules, so an idle session stays listed for as long as its Claude process runs.
- `SessionStore.sorted(_:)` orders by priority (error, needs, working, idle), then by most recent `stateSince`.

## Core: presentation helpers

- `PipLayout.pips(for: [Session], max: 6) -> (states: [BubbleState], overflow: Int)`.
  - Fewer than 2 sessions returns no pips.
  - Up to 6 sessions return one pip each.
  - More than 6 return the first 5 states plus `overflow = count - 5`.
- `ElapsedFormat.string(_ seconds: TimeInterval) -> String` gives `0:42` under 10 min, `22m` under 1 h, `3h` under a day, and `2d` beyond that.

## App: UI

- **Pips:**
  - A SwiftUI row below the orb inside the existing panel. The panel grows to 120×140pt; the orb stays at the top 120×120.
  - Dots are 6pt in each state's main color (`OrbParams.target(for:).c1`), spaced 5pt apart. `+N` uses a small monospaced label.
  - Pips are hidden with fewer than 2 sessions.
- **Hover list (`SessionListPanel`):**
  - A borderless, non-activating floating panel hosting a SwiftUI `SessionListView`.
  - It opens after 300ms of the pointer over the orb (the existing `isOverOrb` hit test). It closes 250ms after the pointer has left both the orb and the list panel.
  - It is anchored below the orb when there's room, otherwise above it, and kept inside the screen's visible frame horizontally.
  - **Styling:** about 290pt wide, 14pt corner radius, dark translucent background (`#17161c` at 96%), and a 1pt border at white 8%.
  - **Row layout:** 26pt mini orb, a bold monospaced project name with the detail underneath, and an elapsed time on the right in secondary monospaced type.
  - **Detail colors:** amber `#f0a050` when the state is needs, red `#e8554f` for error, otherwise secondary gray. The first row gets a subtle highlight.
  - Elapsed times update every second while the list is visible.
  - Clicking a row runs the same `focusTerminal()` as the orb, then closes the list.
- **Mini orbs:** at launch, render each `BubbleState` once offscreen at 96px with the existing shaders, as `NSImage`s cached by state. The icon generator's rendering code moves into a shared `OrbSnapshot` helper in the app target, so `scripts/icon` and the app share one renderer.
- The list and pips read from `SessionWatcher`, which now publishes `[Session]` as well as the combined state.

## Error handling

- Missing or odd hook fields fall back to the defaults above. The hook must still always exit 0.
- If the offscreen render fails, mini orbs fall back to a flat SwiftUI circle in the state's color.
- If `kill` fails for any reason other than `ESRCH`, the session counts as alive, so a session is never hidden by mistake.

## Testing

- **`hook_test.sh`:**
  - `project` from `cwd`, and `"session"` when `cwd` is empty
  - each detail rule
  - `state_since` unchanged across same-state events, and reset on a change
  - `pid` written
  - `tool_ids` correlation: a `PreToolUse` for one tool, a `PermissionRequest` for the same tool, another tool's `PostToolUse` keeping needs, and the matching `PostToolUse` clearing it
- **XCTest:**
  - decoding older files without the new fields
  - liveness: a dead pid dropped and its file deleted, a live pid exempt from staleness, a nil pid using staleness
  - `sorted` ordering
  - `PipLayout`: 0, 1, 2, 6 and 9 sessions
  - `ElapsedFormat` at its boundaries
- **By hand:** the hover open and close timing, the panel flipping near screen edges, and the mini orbs matching the big orb.
