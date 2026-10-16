# Orb Motions Implementation Plan

> Executed inline (native); the user asked for spec and build in one go. Each task is test-first.

**Spec:** `docs/superpowers/specs/2026-10-15-orb-motions-design.md`

## Global Constraints

- **Scope:** main orb only. The pips, pip card and hover list are unchanged.
- **Timing:** hold 0.5s, blend 1.6s; ticks max 3, each under 0.8s, quieting to a 0.3 floor; subagents max 6.
- **Shader:** the shader math is ported from the design (`wkm` modes 0, 2, 9, 12, 17, 23, 24, 25, 26, and the layer block).
- **Commits:** no AI attribution.

## Review Focus

1. **Fast tool bursts** (10 reads in a second): no strobing, and the orb ends on the last target. Covered by `testOnlyLatestTargetIsKept`.
2. **Subagent tool events** while the main agent waits: the motion stays on waiting. Covered by the hook test "subagent tool events keep the activity".
3. **A missed SubagentStop:** the count can't go negative, and a fresh start clears it. Covered by the hook tests.
4. **App launch with sessions holding large counters:** no burst of layers. Covered by `testFirstSightBaselines`.
5. **Focus changes** between sessions: no replayed ticks. Covered by `testFocusSwitchDoesNotReplay`.

---

### Task 1: Core — Motion, MotionDirector, LayerTracker

- **Create:** `Sources/ClaudeBubbleCore/Motions.swift`
- **Test:** `Tests/ClaudeBubbleCoreTests/MotionTests.swift`
- **Produces:**
  - `enum Motion: String { generating, read, search, edit, bash, web, mcp, compacting, waiting }`, with `shaderMode: Float` and `static func forTool(_:) -> Motion`
  - `MotionDirector` with `update(want:now:)` and `frame(now:) -> (from: Motion, to: Motion, mix: Float)`
  - `LayerTracker` with `update(sessions: [(id, ticks, fails, skills)], focus: String?) -> LayerEvents { ticks, fails, skills }`

### Task 2: Animator — layers and motion uniforms

- **Modify:** `OrbAnimator.swift`
  - **Inputs:**
    - `motion: Motion` and `motionElapsed: Double`;
    - `subagents: Int`;
    - `tick()`, `fail()` and `skill()`.
  - **OrbFrame gains:**
    - `workA`, `workB`, `workMix`;
    - `settle`, `sub`;
    - `failAge`, `skillAge`;
    - `tickAges` and `tickAmps` (SIMD3 each).
- **Test:** `Tests/ClaudeBubbleCoreTests/MotionAnimatorTests.swift`

### Task 3: Hook — activity, counters, subagents, compaction

- **Modify:**
  - `hook/claude-bubble-hook.sh`;
  - `HookInstaller.events`, which gains `SubagentStart`, `SubagentStop`, `PreCompact` and `PostCompact`.
- **Test:** `Tests/hook_test.sh` and `HookInstallerTests`.

### Task 4: Session model

- **Modify:** `SessionStore.swift`, where `Session` gains `activity`, `activitySince`, `subagents`, `ticks`, `fails` and `skills`, decoded tolerantly.
- **Test:** `SessionStoreTests`.

### Task 5: Shader and app wiring

- **Modify:**
  - `OrbShaders.swift`: the work modes and layers in the vertex shader; uniforms `f`, `g`, `h`, `i`;
  - `OrbView.swift`;
  - `AppDelegate.swift`: focus session, `LayerTracker`, the animator's inputs;
  - `SimulatorModel` and `SimulatorWindow`: motion picker, layer buttons, the subagent stepper, Play session.
- **Checks:**
  - an offscreen render of each motion;
  - `swift test`, both shell tests and the bundle all pass.
