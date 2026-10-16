# Claude Bubble — Quiet mode

Date: 2026-10-15

## Goal

A switch in the app that gets the bubble out of the way:

- the island or the orb shrinks to a single dot;
- toasts are held and sounds are muted;
- when quiet mode is turned off, the held toasts play back as a quick catch-up.

## Turning it on

- **Where:** the `quiet` preference (saved), toggled by the right-click / menu-bar **Quiet Mode** item or Settings → Quiet mode.
- **No Focus integration.** An earlier draft used a Focus filter and Focus status. Both were dropped at the user's request: Focus status isn't reliably available to a self-signed app, and Do Not Disturb specifically can't be read without Full Disk Access.

## While quiet

- **Island:** a new `quiet` mode, ranked below hover and above everything else.
  - The pill becomes a 16 × 16 dot against its docked edge, fully rounded, in the state colour. The orb, text and pips are hidden.
  - It pulses (breathing scale and glow) when any session needs you or has errored.
  - Hovering it still opens the session panel.
- **Orb:**
  - the orb eases to 0.28 of its size with a calmer glow (`OrbAnimator.quiet`);
  - the pips and the edge light hide;
  - the hover list still works.
- **Toasts:** every toast (session and usage) goes to a hold list (up to 500) instead of the queue. The toasts already showing stay until they expire. Quiet coming back mid catch-up holds the rest again.
- **Also off while quiet:** the hidden pips' hover and spawn pull, the ring pop and the completion flash. Peeking at the island's panel shows the orb at full size.
- **Sounds:** muted.

## Catch-up (`CatchUp`, core)

When quiet mode ends, with H held toasts (oldest first):

- **None held:** nothing plays.
- **H ≤ 5:** they play in order, 0.35s apart.
- **H > 5:** a summary toast plays first, then the 4 most recent (so the summary stays on the five-toast stack), each 0.35s after the previous one.
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
- **Preferences:** `quiet` defaults to off, is saved, and older saved settings decode.
- **By hand:** the toggle, the dot and the catch-up.
