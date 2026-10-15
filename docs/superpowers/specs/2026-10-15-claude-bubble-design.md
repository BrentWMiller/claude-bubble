# Claude Bubble — Design

Date: 2026-10-15

## Goal

A native macOS app that floats a small animated orb on screen showing whether Claude Code is working, waiting on the user, idle, or errored. Glanceable "AI-style" visual, SuperWhisper-overlay feel. No sprites.

Success: at a glance, from across the screen, the user can tell whether any Claude Code session needs them, is busy, or is done — without switching to the terminal.

## Scope

- In: Claude Code CLI sessions on this Mac (via hooks). Four states. Floating orb, menu-bar item, hook installer.
- Out (YAGNI for v1): Claude desktop/web app, per-session orbs, session count badge, click-to-focus terminal, settings window, palette switching, launch-at-login.

## Visual design

Source of truth: Claude Design file `~/Downloads/Claude session status indicator/` (`orbParticles.js`, `orbShared.js`). The Metal port must match it.

The orb is one round shape in every state. It has two layers, blended additively:

1. **Rim/halo quad.** A full-screen fragment shader draws an iridescent ring (three-color mix that rotates with phase), a moving highlight arc, a soft fuzz, an outer halo and a faint inner fill, then tone-maps with `1 - exp(-c*1.4)`.
2. **Particle sphere.** 5,200 points on a Fibonacci sphere, with a twist rotation, a traveling wave band, the error glitch (displaced bands), an `rx(.35)` tilt and a slight perspective. Brightness is limb-weighted; front-facing points are brighter. Each point is a soft round dot.

| State | Colors (C1/C2/C3/Halo) | Motion | Extra |
|---|---|---|---|
| Idle | cool gray-lilac | energy .12, wave .08, glow .35, scale .72 | breathes: sin on a 4s loop over scale ±5%, glow and ring |
| Working | orange / violet / pink, violet halo | energy 1, wave 1, full glow, scale 1 | twisting wave, spinning highlight arc |
| Needs you | amber / coral | energy .22, wave .18, glow .85 | bounce on entry (spring), slow pulse (2.8s period) |
| Error | red | energy .08, wave 0, glitch 1, scale .9 | shake on entry, ring flickers with gaps (8% chance per frame) |

Exact values are copied verbatim from the `PAL.claude` and `MOTION` tables in `orbParticles.js`.

**Transitions.** Every numeric parameter eases toward its target each frame with `k = 1 - 0.02^dt`. The bounce is a damped spring: `bv += (-bounce*220 - bv*14)*dt`. Phase advances at `dt*(.2 + energy*1.5)`.

**Size.** The orb is 72pt. It sits in a transparent window of about 120pt so the halo isn't clipped. Default position is bottom-center, about 80pt above the Dock. It can be dragged and its position is persisted in `UserDefaults`.

## Architecture

```
Claude Code hook events
        │  stdin JSON
        ▼
claude-bubble-hook.sh  ──writes──▶  ~/.claude-bubble/sessions/<session_id>.json
                                              │  (DispatchSource dir watch + 5s poll fallback)
                                              ▼
                       SessionStore (aggregate state, prune stale)
                                              │  @Published BubbleState
                                              ▼
              OrbAnimator (targets, easing, bounce, shake)  ──uniforms──▶  OrbRenderer (MTKView, 2 Metal pipelines)
                                              │
                         BubblePanel (NSPanel: floating, all Spaces, transparent, draggable)
                         MenuBarController (NSStatusItem menu)
```

### Units

- **`hook/claude-bubble-hook.sh`.** Reads the hook JSON from stdin using one `python3` call, the same pattern peon-ping uses. It maps the event to a state and writes `{"state","cwd","event","updated_at"}` atomically (temp file, then `mv`). On `SessionEnd` it deletes the session file. It always exits 0 and never writes to stdout, so it can't interfere with Claude Code. It must finish in under 100ms.
- **`SessionStore`.** Pure-ish Swift. `load(dir, now) -> [Session]` and `aggregate([Session], now) -> BubbleState`. It ignores files whose `updated_at` is more than 15 min old (unless the state is `needs`, which stays alive 60 min). It deletes files older than 24h. Priority is error > needs > working > idle. With no sessions the state is idle. Watching uses `DispatchSource.makeFileSystemObjectSource` on the directory plus a 5s timer, which also re-evaluates staleness.
- **`OrbParams` / `OrbPalette`.** Static tables ported from JS.
- **`OrbAnimator`.** Per-frame `step(dt, now, state) -> OrbFrame`. Easing, phase, idle breath, needs pulse, error flicker, bounce spring, shake offset. Deterministic given its inputs, except the error flicker RNG, which is injectable.
- **`OrbRenderer`.** An `MTKViewDelegate` with two pipelines: a fullscreen-triangle quad shader and a point-sprite shader (`[[point_size]]`, `[[point_coord]]`). Additive blend `one, one`. Clear color is transparent and the layer is non-opaque. The 5,200 points sit in a static vertex buffer. `preferredFramesPerSecond` is 60. When the bubble is hidden, the view is paused.
- **`Shaders.metal`.** A line-for-line port of QFS, PVS and PFS from `orbParticles.js`.
- **`BubblePanel`.** `NSPanel`, borderless, non-activating, `.floating` level, collection behavior `.canJoinAllSpaces` + `.fullScreenAuxiliary`, no shadow, clear background. It is draggable via `isMovableByWindowBackground`. Shake is applied as a view offset.
- **`MenuBarController`.** An `NSStatusItem` with a small SF Symbol tinted by state. Menu items:
  - Show/Hide Bubble
  - Reset Position
  - Install Hooks…
  - Debug ▸ Force Idle/Working/Needs/Error/Live
  - Quit
- **`HookInstaller`.** Copies the hook script to `~/.claude-bubble/hook.sh` and makes it executable. It merges entries into `~/.claude/settings.json` under each event, appending and never replacing. The merge is idempotent (it skips the event if the command is already present). It backs up the file to `settings.json.claude-bubble.bak` first.
- **App.** `LSUIElement` (no Dock icon). Swift Package Manager executable target, built with a small `scripts/bundle.sh` that produces `ClaudeBubble.app` (same approach as voicebox).

## Event → state mapping

| Hook event | State |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit` | working |
| `PreToolUse`, `PostToolUse` | working (returns from needs after a permission is approved) |
| `PermissionRequest` | needs |
| `Notification` with `notification_type == permission_prompt` | needs |
| `Notification` with `idle_prompt` | idle |
| `Stop` | idle |
| `StopFailure` | error |
| `SessionEnd` | delete file |

Lessons taken from peon-ping:
- Events that arrive within 3s of `SessionStart` for the same session (the replay after `claude -c`) are ignored unless they are `UserPromptSubmit`.
- `Stop` events from subagents (`SubagentStop`) are not subscribed to, so they never flip the state to idle mid-task.

`StopFailure` support is checked against the installed Claude Code version during implementation. If it isn't available, the error state stays reachable through Debug only, and this is noted in the README.

## Error handling

- The hook never blocks or fails Claude: everything is wrapped, it always exits 0, and it has a 5s timeout in settings.
- Corrupt or partial JSON files are skipped (atomic writes make these rare).
- A missing sessions dir is created on launch.
- If the Metal device is unavailable, the app falls back to a static SF Symbol in the menu bar only and logs the problem.
- If the installer finds `settings.json` unparseable, it aborts without writing and shows an alert.

## Testing

- **Swift unit tests (`swift test`):**
  - `SessionStore` aggregation priority and staleness rules
  - JSON decoding, including corrupt files
  - `OrbAnimator` easing convergence, bounce decay, shake decay
  - `HookInstaller` merge: idempotent, preserves the existing peon-ping hooks, and writes a backup
- **Hook script test (`tests/hook_test.sh`):** pipe sample JSON for each event into the hook, using a temp HOME, and assert the file contents and the deletion on `SessionEnd`.
- **Visual check:** use the Debug menu to cycle the states and compare side by side with the HTML mockup.
