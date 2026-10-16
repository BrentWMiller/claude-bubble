# Claude Bubble — Quiet mode (Focus and screen share)

Date: 2026-10-15

## Goal

During a Focus you choose (or a screen share, via macOS's "turn on Do Not Disturb when sharing"), the bubble gets out of the way:

- the island or the orb shrinks to a single dot;
- toasts are held and sounds are muted;
- when quiet mode ends, the held toasts play back as a quick catch-up.

## What turns quiet mode on

Quiet mode is on when any of these is true:

1. **Focus Filter.** A Claude Bubble filter is attached to Focus modes in System Settings → Focus → ‹mode› → Focus filters, with a "Quiet mode" switch.
   - The system runs the filter's intent when that Focus turns on (quiet = true) and again when it turns off (quiet = nil).
   - Screen sharing is covered by attaching the filter to Do Not Disturb and turning on its "when mirroring or sharing the screen" option.
2. **Any Focus** (setting `quietAnyFocus`, default off). Uses the system's Focus status (`INFocusStatusCenter`, polled every 2s) after a one-time permission request.
   - If macOS refuses (denied, or restricted for this app), Settings says so and this source stays off.
3. **Manual.** A right-click and menu-bar "Quiet Mode" toggle, kept for the session only.

### Building the filter

- The `ClaudeBubble` target compiles with `-emit-const-values` (the protocol list is in `scripts/appintents-protocols.json`).
- `scripts/bundle.sh` runs `appintentsmetadataprocessor` on the release build's const values and copies `Metadata.appintents` into `Contents/Resources`.
- The intent lives in the app (`QuietFocusFilter: SetFocusFilterIntent`).
- `Info.plist` gains `NSFocusStatusUsageDescription`.

## While quiet

- **Island:** a new `quiet` mode, ranked below hover and above everything else.
  - The pill becomes a 16 × 16 dot against its docked edge, fully rounded, in the state colour. The orb, text and pips are hidden.
  - It pulses (breathing scale and glow) when any session needs you or has errored.
  - Hovering it still opens the session panel.
- **Orb:**
  - the orb eases to 0.28 of its size with a calmer glow (`OrbAnimator.quiet`);
  - the pips and the edge light hide;
  - the hover list still works.
- **Toasts:** every toast (session and usage) goes to a hold list instead of the queue. The toasts already showing stay until they expire.
- **Sounds:** muted.

## Catch-up (`CatchUp`, core)

When quiet mode ends, with H held toasts (oldest first):

- **None held:** nothing plays.
- **H ≤ 5:** they play in order, 0.35s apart.
- **H > 5:** a summary toast plays first, then the 5 most recent, each 0.35s after the previous one.
  - The summary is kind `catchUp`, name "While you were away", with text built from counts. Examples: "3 finished · 1 needs you · 1 error", or "6 updates".
  - "Finished" counts finished, review and all-done toasts.
  - Usage toasts count as updates.

## Testing

- **CatchUp:**
  - nothing held plays nothing;
  - up to five play in order and spaced;
  - over five gives the summary plus the most recent five;
  - the summary text counts and wording.
- **IslandMode:**
  - quiet wins over needs, error, done and rest;
  - hover still wins over quiet;
  - the quiet size.
- **Animator:** quiet scale eases to 0.28 and back.
- **Preferences:** `quietAnyFocus` defaults to off, and older saved settings decode.
- **Build:** the bundle contains `Metadata.appintents` listing `QuietFocusFilter`.
- **By hand:**
  - the filter appears in System Settings → Focus;
  - the manual toggle;
  - the catch-up.
