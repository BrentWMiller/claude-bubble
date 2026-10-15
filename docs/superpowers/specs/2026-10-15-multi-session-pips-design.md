# Claude Bubble — Multi-session pips: arc, choreography, peek, simulator

Date: 2026-10-15
Source design: `~/Downloads/Claude session status indicator (2)/Multi-session Pips.dc.html`
Builds on: the multi-session view, the completed moment.

## Goal

Make the pips a live, readable picture of every session. They sit on an arc and react to each change. Hovering a pip shows that one session. When everything is finished, the orb celebrates once, with all the pips merging into it. A simulator window drives all of this without real sessions.

## States and order

- **Pip states:** needs, error, working, done. "Done" is our existing `idle` (a prompted session that finished).
- **Order:** needs (0), error (1), working (2), done (3); ties by first-seen order.
- **Delayed re-sort on finishing:** a session that finishes keeps its working position for **0.65s** (its flare), then moves to the end.

## Arc

- **Slots:** up to **7**. With more than 7 sessions, ranks 0–5 take the first six slots, and slot 6 shows **+N** where N = count − 6.
- **Angles:** slot `i` of `slots` sits at `(i − (slots − 1)/2) × 11°` from straight down, left to right.
- **Radius:** `orbRadius × 1.28`, where orbRadius = panel side × 0.3. That's the design's 100 / 78 scaled.
- **Visibility:** pips show with **2+ live sessions**, unchanged from before.

## Choreography (`PipChoreographer`, core, deterministic in `now`)

| Event | Pip | Orb |
|---|---|---|
| Spawn | starts at the orb's centre (scale 0.15), then springs to its slot | — |
| → needs | hops twice (up at 0, 0.38s; down at 0.19, 0.57s; −9pt, 1.45×), sorts to front | (aggregate turns amber) |
| → error | shakes sideways 5,−5,4,−4,2,−2,0 pt every 55ms | — |
| → done, others still active | flares white at 2.4× for 0.65s, then retires to the end | **ring pop** (one chromatic ring + sheen) |
| → done, it was the last active | flares, then at 0.9s every pip is pulled into the centre (staggered 0.05s by rank) and fades | **full completion** (working → idle) |
| Any session becomes active while merged | the pips spring back out | — |

## Pip hover

- **Hit area:** the pointer within 7pt of a visible pip's centre hovers it. The pip grows to 1.3× with a ring in its color.
- **Card:** a small card appears under the pip (above it if there's no room below): name, status line (needs = amber, error = red), and time in state.
- **Orb preview:** while hovered, the orb shows that session's state **without** triggering a celebration. Merged pips can't be hovered.

## Orb ring pop

- `OrbAnimator.ringPop()` starts a ~1.6s clock, sent to the shader as `e.x`.
- **Quad pass:** one chromatic ring easing out to 1.5× (the completion's first ring).
- **Particle pass:** a sheen sweeping diagonally from 0.15s to 1.25s.
- It is independent of, and can overlap, the full completion.

## Session Simulator

- **Opening it:** Debug ▸ **Session Simulator…** in both the menu-bar menu and the orb's menu. It opens a SwiftUI window.
- **Controls:**
  - **+ Add session**, using the names from the design's pool in order;
  - per session: name, **Work / Needs / Error / Done** buttons (current one highlighted), and ×;
  - **Play story:** the design's 14-second script;
  - **Reset**.
- **While the window is open:** the orb, pips, hover list and pip card show only simulated sessions. Simulated status lines come from the design: "Running tests", "Approve edit to auth.ts?", "Build failed · exit 1", "Completed".
- **Closing it** returns to live data. Simulated sessions never touch the session files.

## Testing

- **Choreographer:**
  - order and ties;
  - overflow;
  - spawn-from-centre then settle;
  - the hop and shake schedules;
  - the flare, then retiring at 0.65s;
  - ring pop when others are active, and none when it's the last;
  - merge at 0.9s when all are done, un-merge on new activity;
  - arc positions.
- **Animator:** ring pop timing; a quiet `setState` never celebrates.
- **Story:** the step timeline, ending with all three done.
- **By hand:** the motion and the card, through the simulator.
