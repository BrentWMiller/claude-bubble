# Claude Bubble — Orb motions and layers

Date: 2026-10-15
Source design: `~/Downloads/Claude session status indicator (7)/Orb States.dc.html` and its `orbParticles.js` (work modes, layers).
Scope: **the main orb only.** The pips, the pip card and the hover list are unchanged.

## Goal

While Claude is working, the orb's motion shows what it is doing (reading, searching, editing, running a command, …), and small layers mark tool completions, failures, skills and subagents. Colours still come from the theme; this is movement and shape only.

## Motions

These replace the working swirl while the state is **working**. Each has a shader mode number from the design's `WORK` table.

| Motion | Shader mode | Design name | Signal |
|---|---|---|---|
| generating | 0 (wave) | Rolling wave (today's working motion) | after a prompt, after a tool ends, any tool not listed below |
| read | 17 (converge) | Converge | `Read`, `NotebookRead` |
| search | 12 (radar) | Radar | `Grep`, `Glob`, `LSP`, `ToolSearch` |
| edit | 2 (ripple) | Emit | `Edit`, `Write`, `MultiEdit`, `NotebookEdit` |
| bash | 26 (bash) | Boil → simmer | `Bash`, `PowerShell`; settles with time since it started (`settle = 1 − e^(−elapsed/6)`, eased) |
| web | 9 (drift) | Drifting ripple | `WebFetch`, `WebSearch` |
| mcp | 23 (link) | Link | any `mcp__…` tool |
| compacting | 24 (compact) | Fold | `PreCompact` until `PostCompact` (or the compact `SessionStart`) |
| waiting | 25 (wait) | Still + sources | the main agent's `Task`/`Agent` tool call, until it returns |

- **Other states:** needs, error and idle keep their own looks. Leaving working, the target becomes generating, so the work motion blends away with the state change.
- **Subagent events:** tool events that come from a subagent (the hook input has `agent_id`) never change the motion. Their completions still count as ticks.

### Scheduling (`MotionDirector`, core)

- **Hold:** a new target is taken only after the shown target has held for at least **0.5s**.
- **Blend:** blends take **1.6s** (smoothstep).
- **Queued switch:** a switch that arrives mid-blend waits until the current blend finishes; only the latest target is kept.
- **Output:** `(from, to, mix)` for the shader.

## Layers

| Layer | Trigger | Shader (ported from the design) |
|---|---|---|
| Tick | a tool call completed | a small fast ring from the front point, gone within 0.8s. Up to 3 at once. Amplitude `max(0.3, 1 / (1 + 0.35·(n−1)))`, where n = ticks in the last 1.5s, so bursts get quieter |
| Dent | a tool call failed | an inward pinch on the upper-left front for about 1.2s, plus a small jolt (shake 0.3) |
| Interference | subagents running (count, up to 6) | one ripple source per subagent, each quieter. The count eases (`1 − 0.06^dt`). The base motion ducks by `min(n,3)·0.18` |
| Sweep | a skill or plan-mode tool (`Skill`, `EnterPlanMode`, `ExitPlanMode`) | a plane of light sweeps across over 1.6s, with a quick spin (phase boost for 1.4s) |

## Data (hook)

Each session file gains these fields:

- **`activity`:** one of the motion names above.
- **`activity_since`:** epoch seconds when the current activity began.
- **`subagents`:** the ids of running subagents.
  - Added on `SubagentStart`, removed on `SubagentStop`.
  - Cleared on a fresh start.
  - Read as a count.
- **`ticks`, `fails`, `skills`:** running counters. They are only ever increased; the app fires a layer when one goes up, so a burst between two file reads isn't lost.
  - `ticks` goes up on `PostToolUse`;
  - `fails` on `PostToolUseFailure`;
  - `skills` on `PreToolUse` of a skill or plan tool.

- **New hook subscriptions:** `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`. They keep the session's current state (working if it had none) and only update the fields above.
- **Activity transitions:**
  - `UserPromptSubmit` → generating;
  - `PreToolUse` (main agent) → the tool's motion;
  - `PostToolUse` / `PostToolUseFailure` (main agent) → generating;
  - `PreCompact` → compacting; `PostCompact` → generating.
  - Any other event leaves the activity as it is.

## App

- **Focus:** the session that drives the orb is the working session updated most recently. With none working, the motion is generating. A pip hover still previews only the state (unchanged).
- **Layers:**
  - **Fire:** a layer fires when the focus session's counter goes up since the last read.
  - **Baseline:** each session's counters are baselined on first sight. Launching, or switching focus, never replays old counts.
- **Bash settle:** for bash, elapsed = now − `activity_since`.
- **Uniforms:** the shader gets the from/to modes, the mix, the settle, the subagent count, the fail and skill ages, three tick ages and three tick amplitudes. That's four new float4s: `f`, `g`, `h`, `i`.

## Simulator

Per session:
- a **motion** picker (it applies while the session is working);
- **Tick**, **Fail**, **Skill** buttons;
- a **subagents** stepper (0–6).

**Play session** (session-wide) runs the design's 40-second script on one simulated session.

## Testing

- **MotionDirector:** the hold, the blend progress, the queued switch, only the latest target being kept, and settling on the final target.
- **Animator:**
  - tick amplitude decays in bursts, with at most 3 ticks;
  - fail and skill ages;
  - the subagent count eases;
  - the settle eases;
  - motion targets generating when not working.
- **Activity mapping (core):** each tool name maps to its motion.
- **Hook (shell):**
  - each transition above;
  - subagent tool events don't change the activity;
  - the counters increase;
  - the subagent set, including stop for an unknown id;
  - the compact cycle;
  - the new events keep the state.
- **Focus and layer firing (core):**
  - baselines on first sight, then fires on increases;
  - a focus switch doesn't replay.
- **Offscreen renders** of every motion, compared by eye with the design.
