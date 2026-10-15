# Multi-session Pips Implementation Plan

> Executed inline (native); the user asked for spec and build in one go. Each task is test-first; tests live in the repo files named below.

**Spec:** `docs/superpowers/specs/2026-10-15-multi-session-pips-design.md`

## Global Constraints

- **Timings and amplitudes** are exactly as in the spec table (0.65s retire, 0.9s merge, hop and shake schedules, 11° arc step, max 7 slots).
- **Pips** show only with 2+ live sessions.
- **Hover previews** never trigger the completion celebration.
- **Simulated sessions** never touch the session files.
- **Commits:** no AI attribution.

## Review Focus

1. **A session flips states rapidly** (done → working within 0.65s): no stale flare, no leftover retire timer moving it to the end. Covered by `testReturningToWorkCancelsTheRetire`.
2. **The last session finishes while another is removed in the same update:** the merge still happens once, and there's no ring pop. Covered by `testRemovingTheLastActiveDuringFinishMergesCleanly`.
3. **More than 7 sessions with a hovered pip in overflow:** hidden pips can't be hovered. Covered by `testHiddenPipsAreNotHittable`.
4. **Simulator closed mid-story:** timers stop, and live data returns. The story timers are owned by the simulator model and cancelled on close (checked by hand).
5. **Hovering while merged:** no card and no orb preview. Covered by `testMergedPipsAreNotHittable`.

---

### Task 1: Animator — ring pop and quiet state changes

- **Modify:** `OrbAnimator.swift`
- **Test:** `Tests/ClaudeBubbleCoreTests/RingPopTests.swift`
- **Produces:**
  - `OrbAnimator.ringPop()`
  - `OrbFrame.pop: Float` (−1 when idle)
  - `setState(_:quiet:)`, where `quiet: true` never starts the completion

### Task 2: PipChoreographer and arc geometry

- **Create:** `Sources/ClaudeBubbleCore/PipChoreographer.swift`
- **Test:** `Tests/ClaudeBubbleCoreTests/PipChoreographerTests.swift`
- **Produces:**
  - `PipInput(id:state:)`
  - `PipChoreographer.update(_ inputs: [PipInput], now:) -> [PipEvent]`, with `PipEvent = .ringPop`
  - `frame(now:) -> PipsFrame`, holding `pips: [PipFrame]`, `slots`, `overflow`, `merged`
  - `PipFrame { id, state, slot: Int?, rank: Int, atCenter, flaring, hopping, shake: Double }`
  - `PipArc.position(slot:slots:centre:radius:) -> CGPoint` (y-down view space)
  - `PipArc.hit(_ point:, frame:, centre:, radius:) -> String?`
- **Removes:** the old `PipLayout` (superseded), along with its tests.

### Task 3: Simulator story timeline

- **Create:** `Sources/ClaudeBubbleCore/SimulatorStory.swift`
- **Test:** `SimulatorStoryTests.swift`
- **Produces:**
  - `SimulatorStory.steps: [Step]`, where `Step { at: Double; action: .add(name, state) | .set(index, state) }`
  - `SimulatorStory.namePool`
  - `SimulatorStory.detail(for:)`

### Task 4: App — arc pips, pip card, ring pop shader, simulator window, wiring

- **Create:** `SimulatorModel.swift`, `SimulatorWindow.swift`, `PipCardPanel.swift`
- **Modify:**
  - `SessionViews.swift`: `ArcPipsView` replaces `PipsView`
  - `SessionsModel.swift`: `pips`, `hoveredPip`
  - `OrbShaders.swift` and `OrbView.swift`: uniform `e` carries the ring pop
  - `AppDelegate.swift`:
    - the choreographer is updated on every tick, and its ring-pop events go to the animator;
    - pip hover drives the card and a quiet orb preview;
    - the simulator source switch;
    - Debug menu items
  - `BubblePanel.swift`: the pip host stays click-through; hover is computed from pointer math
- **Checks:**
  - `swift test`, the hook tests, `scripts/bundle.sh` and `scripts/make-icon.sh` all pass;
  - an offscreen render of the ring pop;
  - by hand, through the simulator.
